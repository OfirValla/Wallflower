package com.auradisplay.kiosk.power

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import com.auradisplay.kiosk.AuraConfig
import com.auradisplay.kiosk.AuraCore
import java.lang.ref.WeakReference

/**
 * Display power and brightness.
 *
 * There are two honest ways to "turn a kiosk display off", with a real
 * trade-off, so Aura implements both and lets the operator choose:
 *
 * **`dim`** (default) - drive the window backlight to 0 and let Flutter paint a
 * black overlay. The panel is still technically on, so:
 *   + wake is instantaneous, there is never a keyguard, the WebView stays warm
 *   + no permissions, works on every device
 *   - an OLED shows true black but an LCD still leaks backlight, and the panel
 *     still draws a few hundred mW
 *
 * **`deviceLock`** - `DevicePolicyManager.lockNow()`. The panel genuinely turns
 * off.
 *   + real power saving, real black
 *   - needs device admin, wake takes ~300-800 ms, and waking requires a
 *     deprecated `ACQUIRE_CAUSES_WAKEUP` wake lock plus an activity re-front
 *
 * `dim` is the right default for a mains-powered wall dashboard.
 */
class ScreenController(context: Context) {

    private val appContext: Context = context.applicationContext
    private val powerManager = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val dpm =
        appContext.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
    private val main = Handler(Looper.getMainLooper())

    private var activityRef: WeakReference<Activity> = WeakReference(null)

    @Volatile
    private var config: AuraConfig = AuraConfig()

    /** Aura's logical screen state, which is what Home Assistant is told. */
    @Volatile
    var isScreenOn: Boolean = true
        private set

    @Volatile
    var brightness: Int = 255
        private set

    private var idleTimer: Runnable? = null

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------

    fun attach(activity: Activity) {
        activityRef = WeakReference(activity)
        applyBrightness(brightness)
        rearmIdleTimer()
    }

    fun detach(activity: Activity) {
        if (activityRef.get() === activity) activityRef = WeakReference(null)
    }

    fun updateConfig(next: AuraConfig) {
        val brightnessChanged = next.brightness != config.brightness
        val timeoutChanged = next.screenTimeoutSeconds != config.screenTimeoutSeconds
        config = next
        if (brightnessChanged && isScreenOn) setBrightness(next.brightness)
        if (timeoutChanged) rearmIdleTimer()
    }

    fun state(): Map<String, Any?> = mapOf(
        "screenOn" to isScreenOn,
        "brightness" to brightness,
        // The OS view of things, which can differ from ours in `dim` mode.
        "interactive" to powerManager.isInteractive,
        "screenOffMode" to config.screenOffMode,
        "canWriteSettings" to Settings.System.canWrite(appContext),
    )

    // ---------------------------------------------------------------------
    // Public commands (screen_on / screen_off / set_brightness)
    // ---------------------------------------------------------------------

    fun setScreen(on: Boolean, reason: String = "command"): Boolean {
        if (on) wake(reason) else sleep(reason)
        return true
    }

    fun wake(reason: String = "command") {
        val wasOff = !isScreenOn
        isScreenOn = true
        cancelIdleTimer()

        when (config.screenOffMode) {
            AuraConfig.MODE_DEVICE_LOCK -> if (!powerManager.isInteractive) forceDisplayOn()
            else -> applyBrightness(brightness)
        }

        rearmIdleTimer()
        if (wasOff) {
            Log.i(TAG, "Display woken ($reason)")
            AuraCore.emit(EVENT_SCREEN, state() + mapOf("reason" to reason))
        }
    }

    fun sleep(reason: String = "command") {
        if (!isScreenOn) return
        isScreenOn = false
        cancelIdleTimer()

        when (config.screenOffMode) {
            AuraConfig.MODE_DEVICE_LOCK -> {
                // Requires an active device admin with the force-lock policy.
                val ok = runCatching { dpm.lockNow() }.isSuccess
                if (!ok) {
                    Log.w(TAG, "lockNow() denied - falling back to dim")
                    applyBrightness(0)
                }
            }

            else -> applyBrightness(0)
        }

        Log.i(TAG, "Display slept ($reason)")
        AuraCore.emit(EVENT_SCREEN, state() + mapOf("reason" to reason))
    }

    /** @param value 0..255, matching Home Assistant's light brightness scale. */
    fun setBrightness(value: Int): Boolean {
        brightness = value.coerceIn(0, 255)
        if (isScreenOn) applyBrightness(brightness)
        AuraCore.emit(EVENT_SCREEN, state() + mapOf("reason" to "brightness"))
        return true
    }

    /** Called from `Activity.onUserInteraction()` and by the touch-to-wake tap. */
    fun noteInteraction() {
        if (!isScreenOn) {
            wake("touch")
        } else {
            rearmIdleTimer()
        }
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    private fun applyBrightness(value255: Int) {
        if (config.useSystemBrightness && Settings.System.canWrite(appContext)) {
            applySystemBrightness(value255)
            return
        }
        // Window-scoped brightness needs no permission and is instant. It only
        // affects our window - which is fine, because in kiosk mode our window
        // is the only thing on screen.
        val fraction = if (value255 <= 0) 0f else (value255 / 255f).coerceIn(0.004f, 1f)
        val act = activityRef.get() ?: return
        main.post {
            runCatching {
                val attrs: WindowManager.LayoutParams = act.window.attributes
                attrs.screenBrightness = fraction
                act.window.attributes = attrs
            }.onFailure { Log.w(TAG, "Window brightness failed", it) }
        }
    }

    private fun applySystemBrightness(value255: Int) {
        runCatching {
            Settings.System.putInt(
                appContext.contentResolver,
                Settings.System.SCREEN_BRIGHTNESS_MODE,
                Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL,
            )
            Settings.System.putInt(
                appContext.contentResolver,
                Settings.System.SCREEN_BRIGHTNESS,
                value255.coerceIn(0, 255),
            )
        }.onFailure { Log.w(TAG, "System brightness failed", it) }
    }

    /**
     * Turns a genuinely-off panel back on.
     *
     * `FULL_WAKE_LOCK` is deprecated and every replacement suggestion
     * (`setTurnScreenOn` + activity re-front) only works when the activity is
     * actually restarted. In practice the reliable recipe on real kiosk
     * hardware is: brief `ACQUIRE_CAUSES_WAKEUP` lock *and* re-front the
     * activity, then let the manifest `turnScreenOn` attribute finish the job.
     */
    @Suppress("DEPRECATION")
    private fun forceDisplayOn() {
        runCatching {
            val lock = powerManager.newWakeLock(
                PowerManager.FULL_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                WAKE_TAG,
            )
            lock.acquire(WAKE_HOLD_MS)
            main.postDelayed({ runCatching { if (lock.isHeld) lock.release() } }, WAKE_HOLD_MS)
        }.onFailure { Log.w(TAG, "ACQUIRE_CAUSES_WAKEUP failed", it) }

        if (AuraCore.isInitialized) AuraCore.kiosk.bringToForeground()
        applyBrightness(brightness)
    }

    private fun rearmIdleTimer() {
        cancelIdleTimer()
        val seconds = config.screenTimeoutSeconds
        if (seconds <= 0 || !isScreenOn) return
        val task = Runnable { sleep("timeout") }
        idleTimer = task
        main.postDelayed(task, seconds * 1_000L)
    }

    private fun cancelIdleTimer() {
        idleTimer?.let { main.removeCallbacks(it) }
        idleTimer = null
    }

    private companion object {
        const val TAG = "AuraScreen"
        const val EVENT_SCREEN = "screenState"
        const val WAKE_TAG = "AuraDisplay:wake"
        const val WAKE_HOLD_MS = 3_000L
    }
}
