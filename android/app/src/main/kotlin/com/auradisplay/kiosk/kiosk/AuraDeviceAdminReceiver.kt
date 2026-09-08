package com.auradisplay.kiosk.kiosk

import android.app.admin.DeviceAdminReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import com.auradisplay.kiosk.AuraCore

/**
 * Device Admin / Device Owner entry point.
 *
 * Registering this receiver is what unlocks the difference between "pretty
 * fullscreen browser" and "real kiosk":
 *
 *  - `lockNow()` for a genuine display-off
 *  - Lock Task whitelisting (no confirmation dialog, HOME/RECENTS dead)
 *  - `setStatusBarDisabled()` - the only reliable way to kill the shade
 *  - runtime permission auto-grant, so a headless wall unit never blocks on a
 *    permission dialog nobody is standing there to tap
 *
 * Provisioning (device must have zero accounts - factory reset first):
 * ```
 * adb shell dpm set-device-owner \
 *   com.auradisplay.kiosk/.kiosk.AuraDeviceAdminReceiver
 * ```
 */
class AuraDeviceAdminReceiver : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        Log.i(TAG, "Device admin enabled")
        // Re-assert policy: an operator may have just promoted us to Device
        // Owner, which makes a whole set of calls newly legal.
        runCatching { AuraCore.ensureInitialized(context).kiosk.applyDeviceOwnerPolicies() }
            .onFailure { Log.w(TAG, "Policy re-apply failed", it) }
        AuraCore.emit(EVENT, mapOf("adminActive" to true))
    }

    override fun onDisabled(context: Context, intent: Intent) {
        Log.w(TAG, "Device admin disabled - kiosk lockdown is now best-effort")
        AuraCore.emit(EVENT, mapOf("adminActive" to false))
    }

    override fun onLockTaskModeEntering(context: Context, intent: Intent, pkg: String) {
        Log.i(TAG, "Lock Task entered for $pkg")
        AuraCore.emit(EVENT, mapOf("lockTaskActive" to true))
    }

    override fun onLockTaskModeExiting(context: Context, intent: Intent) {
        Log.w(TAG, "Lock Task exited")
        AuraCore.emit(EVENT, mapOf("lockTaskActive" to false))
    }

    /** Fired when provisioned as Profile Owner via an NFC/QR enrolment flow. */
    override fun onProfileProvisioningComplete(context: Context, intent: Intent) {
        runCatching { AuraCore.ensureInitialized(context).kiosk.applyDeviceOwnerPolicies() }
        val launch = Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .setPackage(context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(launch) }
    }

    companion object {
        private const val TAG = "AuraDeviceAdmin"
        private const val EVENT = "kioskStatus"

        fun component(context: Context): ComponentName =
            ComponentName(context.applicationContext, AuraDeviceAdminReceiver::class.java)
    }
}
