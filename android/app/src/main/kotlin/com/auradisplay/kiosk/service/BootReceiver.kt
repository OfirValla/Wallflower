package com.auradisplay.kiosk.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.auradisplay.kiosk.MainActivity

/**
 * Brings the dashboard back after a power cut.
 *
 * Deliberately starts the **Activity**, not the service:
 *
 *  - a camera-type foreground service started from BOOT_COMPLETED throws
 *    `ForegroundServiceStartNotAllowedException` on Android 15+
 *  - the Activity is allowed to start the service the moment it is visible
 *  - and the Activity is what the user actually needs on screen anyway
 *
 * If Aura is configured as the device Home app (the recommended setup), the
 * system launches it at boot on its own and this receiver is just a backstop
 * for OEM ROMs that skip that. Some aggressive OEM skins (Xiaomi, Huawei,
 * Oppo) additionally require the app to be whitelisted for "autostart" in
 * their own settings - no manifest entry can substitute for that.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in BOOT_ACTIONS) return
        Log.i(TAG, "Boot completed (${intent.action}) - launching kiosk")

        val launch = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra(EXTRA_FROM_BOOT, true)
        }
        runCatching { context.startActivity(launch) }
            .onFailure { Log.e(TAG, "Boot launch blocked", it) }
    }

    companion object {
        private const val TAG = "AuraBoot"
        const val EXTRA_FROM_BOOT = "aura.from_boot"

        private val BOOT_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )
    }
}
