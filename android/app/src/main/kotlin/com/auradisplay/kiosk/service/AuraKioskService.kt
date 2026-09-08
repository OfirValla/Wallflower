package com.auradisplay.kiosk.service

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import com.auradisplay.kiosk.AuraCore
import com.auradisplay.kiosk.MainActivity
import com.auradisplay.kiosk.R

/**
 * The always-on half of Aura Display.
 *
 * Extends [LifecycleService] rather than plain `Service` for one specific
 * reason: CameraX `bindToLifecycle()` needs a real [androidx.lifecycle.Lifecycle],
 * and binding the motion pipeline to the *service* instead of the Activity is
 * what lets frame analysis continue while the display is off.
 *
 * Responsibilities:
 *  - hold the foreground-service slot so the OS never freezes our process,
 *    throttles the MQTT socket, or defers WebView timers
 *  - hold a PARTIAL_WAKE_LOCK so motion analysis and MQTT survive display-off
 *  - own the motion pipeline lifecycle
 *
 * Notably *not* here: MQTT and the REST server. Those live in Dart, because a
 * kiosk Activity never leaves the foreground, so the Dart isolate is always
 * scheduled. If you ever need the HA link to survive the Activity being
 * destroyed, that is the piece to move down here - see ARCHITECTURE.md.
 */
class AuraKioskService : LifecycleService() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        AuraCore.ensureInitialized(this)
        createNotificationChannel()
    }

    override fun onBind(intent: Intent): IBinder? = super.onBind(intent)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Dispatches Lifecycle.Event.ON_START, which is the state CameraX needs
        // before it will open the camera.
        super.onStartCommand(intent, flags, startId)

        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        promoteToForeground()
        acquireWakeLock()
        AuraCore.motion.start(this)

        // START_STICKY: if the OS ever kills us for memory, come back.
        return START_STICKY
    }

    override fun onDestroy() {
        AuraCore.motion.shutdown()
        releaseWakeLock()
        super.onDestroy()
    }

    // ---------------------------------------------------------------------
    // Foreground promotion
    // ---------------------------------------------------------------------

    private fun promoteToForeground() {
        val notification = buildNotification()

        // Declare the narrowest set of types that actually applies. Asking for
        // `camera` when motion detection is off would be both a policy problem
        // and a needless restriction on when the service may start.
        var types = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            types = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            if (AuraCore.motion.needsCameraServiceType && hasCameraPermission()) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
        }

        try {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, types)
        } catch (t: Throwable) {
            // Two realistic failures:
            //  * ForegroundServiceStartNotAllowedException - we were started
            //    from the background (e.g. someone wired this to BOOT_COMPLETED
            //    on Android 15, where camera-type FGS from boot is illegal).
            //  * SecurityException - a FOREGROUND_SERVICE_* permission missing.
            // Retry as special-use only; if that also fails, give up quietly
            // rather than crashing a wall display at 3am.
            Log.e(TAG, "startForeground($types) failed, retrying without camera type", t)
            runCatching {
                val fallback =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                    } else {
                        0
                    }
                ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, fallback)
            }.onFailure { Log.e(TAG, "startForeground fallback failed", it) }
        }
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.service_notification_title))
            .setContentText(getString(R.string.service_channel_description))
            .setSmallIcon(R.drawable.ic_aura)
            .setContentIntent(open)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.service_channel_name),
            // LOW: visible in the shade, never makes a sound, never peeks.
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.service_channel_description)
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_SECRET
        }
        manager.createNotificationChannel(channel)
    }

    // ---------------------------------------------------------------------
    // Wake lock
    // ---------------------------------------------------------------------

    /**
     * A held-forever PARTIAL_WAKE_LOCK is normally an anti-pattern. It is the
     * correct call here: this is a mains-powered appliance whose entire purpose
     * is to stay responsive, and without it Doze will suspend the MQTT socket
     * and the motion thread the moment the display goes dark.
     */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG).apply {
            setReferenceCounted(false)
            acquire()
        }
        Log.i(TAG, "Partial wake lock acquired")
    }

    private fun releaseWakeLock() {
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        wakeLock = null
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    companion object {
        private const val TAG = "AuraKioskService"
        private const val CHANNEL_ID = "aura_kiosk"
        private const val NOTIFICATION_ID = 1001
        private const val WAKE_TAG = "AuraDisplay:service"
        const val ACTION_STOP = "com.auradisplay.kiosk.action.STOP"

        /**
         * Must be called from a visible Activity. Starting a camera-type
         * foreground service from the background is rejected on Android 12+
         * and hard-rejected from BOOT_COMPLETED on Android 15+.
         */
        fun start(context: Context) {
            val intent = Intent(context, AuraKioskService::class.java)
            runCatching { ContextCompat.startForegroundService(context, intent) }
                .onFailure { Log.e(TAG, "Service start rejected", it) }
        }

        fun stop(context: Context) {
            val intent = Intent(context, AuraKioskService::class.java).setAction(ACTION_STOP)
            runCatching { context.startService(intent) }
        }
    }
}
