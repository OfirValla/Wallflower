package com.auradisplay.kiosk.kiosk

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.auradisplay.kiosk.AuraConfig
import com.auradisplay.kiosk.MainActivity
import java.lang.ref.WeakReference

/**
 * Owns every lockdown concern in one place.
 *
 * Aura has three escalating levels of lockdown, and the manager degrades
 * gracefully between them rather than failing:
 *
 *  1. **Immersive** (no permissions) - system bars hidden, hardware keys
 *     swallowed, screen kept awake. Anyone can leave with a swipe + HOME.
 *  2. **Screen pinning** (no permissions) - `startLockTask()` without Device
 *     Owner. The OS shows a confirmation and the user can escape with
 *     BACK+RECENTS held together.
 *  3. **Device Owner Lock Task** (provisioned) - the real thing. HOME and
 *     RECENTS are dead, the status bar is disabled by policy, the keyguard is
 *     suppressed and the app cannot be uninstalled.
 *
 * Everything window-scoped (immersive, FLAG_KEEP_SCREEN_ON, Lock Task itself)
 * needs a live Activity, so the manager holds a weak reference that MainActivity
 * attaches and detaches. Everything policy-scoped works off the app context.
 */
class KioskManager(context: Context) {

    private val appContext: Context = context.applicationContext
    private val dpm = appContext.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
    private val admin: ComponentName = AuraDeviceAdminReceiver.component(appContext)
    private val barBlocker = SystemBarBlocker(appContext)

    private var activityRef: WeakReference<Activity> = WeakReference(null)
    private val activity: Activity? get() = activityRef.get()

    @Volatile
    private var config: AuraConfig = AuraConfig()

    // ---------------------------------------------------------------------
    // Capability probing
    // ---------------------------------------------------------------------

    val isAdminActive: Boolean get() = dpm.isAdminActive(admin)

    val isDeviceOwner: Boolean get() = dpm.isDeviceOwnerApp(appContext.packageName)

    private val lockTaskState: Int
        get() = (appContext.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
            .lockTaskModeState

    val isLockTaskActive: Boolean
        get() = lockTaskState != ActivityManager.LOCK_TASK_MODE_NONE

    fun status(): Map<String, Any?> = mapOf(
        "adminActive" to isAdminActive,
        "deviceOwner" to isDeviceOwner,
        "lockTaskActive" to isLockTaskActive,
        // 0 = none, 1 = locked (Device Owner), 2 = pinned (user confirmed)
        "lockTaskState" to lockTaskState,
        "statusBarBlockedByPolicy" to isDeviceOwner,
        "touchShieldActive" to barBlocker.isShowing,
        "canDrawOverlays" to barBlocker.canDrawOverlays(),
        "canWriteSettings" to Settings.System.canWrite(appContext),
        "isHomeApp" to isDefaultHomeApp(),
        "activityAttached" to (activity != null),
    )

    fun updateConfig(next: AuraConfig) {
        config = next
        activity?.let { applyWindowPolicy(it) }
        syncTouchShield()
    }

    // ---------------------------------------------------------------------
    // Activity lifecycle
    // ---------------------------------------------------------------------

    fun attach(activity: Activity) {
        activityRef = WeakReference(activity)
        applyWindowPolicy(activity)
    }

    fun detach(activity: Activity) {
        if (activityRef.get() === activity) activityRef = WeakReference(null)
    }

    /**
     * Full engage. Safe to call repeatedly - every step is idempotent, which
     * matters because we re-run it on resume and on config change.
     */
    fun engage(): Map<String, Any?> {
        applyDeviceOwnerPolicies()
        val act = activity
        if (act != null) {
            applyWindowPolicy(act)
            if (config.lockTaskEnabled) startLockTask()
        }
        syncTouchShield()
        return status()
    }

    fun release() {
        stopLockTask()
        barBlocker.hide()
        if (isDeviceOwner) {
            runCatching { dpm.setStatusBarDisabled(admin, false) }
            runCatching { dpm.setKeyguardDisabled(admin, false) }
        }
        activity?.let { act ->
            act.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            WindowInsetsControllerCompat(act.window, act.window.decorView)
                .show(WindowInsetsCompat.Type.systemBars())
        }
    }

    // ---------------------------------------------------------------------
    // Window policy: immersive + keep-awake
    // ---------------------------------------------------------------------

    fun applyWindowPolicy(act: Activity) {
        val window = act.window

        // Keep the display awake for as long as this window is visible. This is
        // the correct primitive - a SCREEN_BRIGHT wake lock is deprecated and
        // fights the OS. The service additionally holds a PARTIAL_WAKE_LOCK so
        // MQTT and motion analysis survive a display-off.
        if (config.keepScreenOn) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }

        // Let a motion wake-up land straight on the dashboard.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            act.setShowWhenLocked(true)
            act.setTurnScreenOn(true)
        }
        if (config.dismissKeyguard) {
            val km = act.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            runCatching { km.requestDismissKeyguard(act, null) }
        }

        applyImmersive(act, config.immersive)
    }

    /**
     * Re-hide the system bars. Must be called from
     * `Activity.onWindowFocusChanged` and after any transient-bar swipe,
     * otherwise the bars stay up until the next configuration change.
     */
    fun applyImmersive(act: Activity, enabled: Boolean = config.immersive) {
        val window = act.window
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        if (enabled) {
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    // ---------------------------------------------------------------------
    // Lock Task
    // ---------------------------------------------------------------------

    fun startLockTask(): Boolean {
        val act = activity ?: return false
        if (isLockTaskActive) return true
        return try {
            act.startLockTask()
            Log.i(TAG, "Lock Task requested (deviceOwner=$isDeviceOwner)")
            true
        } catch (e: IllegalArgumentException) {
            // Thrown when the package is not whitelisted and pinning is refused.
            Log.e(TAG, "Lock Task refused", e)
            false
        } catch (e: SecurityException) {
            Log.e(TAG, "Lock Task not permitted", e)
            false
        }
    }

    fun stopLockTask(): Boolean {
        val act = activity ?: return false
        if (!isLockTaskActive) return true
        return runCatching { act.stopLockTask() }.isSuccess
    }

    // ---------------------------------------------------------------------
    // Device Owner policy
    // ---------------------------------------------------------------------

    /**
     * Applies every policy that requires Device Owner. No-ops safely when we
     * are only a plain device admin, so callers never have to branch.
     */
    fun applyDeviceOwnerPolicies() {
        if (!isDeviceOwner) {
            Log.i(TAG, "Not Device Owner - skipping policy application")
            return
        }

        // Whitelist ourselves so startLockTask() enters real Lock Task with no
        // user confirmation.
        runCatching { dpm.setLockTaskPackages(admin, arrayOf(appContext.packageName)) }
            .onFailure { Log.w(TAG, "setLockTaskPackages failed", it) }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            var features = DevicePolicyManager.LOCK_TASK_FEATURE_NONE
            if (!config.blockStatusBar) {
                features = features or
                    DevicePolicyManager.LOCK_TASK_FEATURE_SYSTEM_INFO or
                    DevicePolicyManager.LOCK_TASK_FEATURE_NOTIFICATIONS
            }
            // Long-press-power menu. Off by default: on a public display it is
            // an escape hatch. Hard power-off still works.
            if (config.allowPowerMenu) {
                features = features or DevicePolicyManager.LOCK_TASK_FEATURE_GLOBAL_ACTIONS
            }
            runCatching { dpm.setLockTaskFeatures(admin, features) }
                .onFailure { Log.w(TAG, "setLockTaskFeatures failed", it) }
        }

        // The reliable status-bar kill. Works outside Lock Task too.
        runCatching { dpm.setStatusBarDisabled(admin, config.blockStatusBar) }
            .onFailure { Log.w(TAG, "setStatusBarDisabled failed", it) }

        // No lock screen between a motion wake-up and the dashboard.
        if (config.dismissKeyguard) {
            runCatching { dpm.setKeyguardDisabled(admin, true) }
                .onFailure { Log.w(TAG, "setKeyguardDisabled failed", it) }
        }

        // Belt and braces for keep-awake: this survives our process dying.
        runCatching {
            dpm.setGlobalSetting(
                admin,
                Settings.Global.STAY_ON_WHILE_PLUGGED_IN,
                (
                    BatteryManager.BATTERY_PLUGGED_AC or
                        BatteryManager.BATTERY_PLUGGED_USB or
                        BatteryManager.BATTERY_PLUGGED_WIRELESS
                    ).toString(),
            )
        }.onFailure { Log.w(TAG, "STAY_ON_WHILE_PLUGGED_IN failed", it) }

        // 0 = "no admin-imposed limit"; we own the display timeout ourselves.
        runCatching { dpm.setMaximumTimeToLock(admin, 0L) }

        // A wall-mounted unit has nobody to tap a permission dialog.
        autoGrant(Manifest.permission.CAMERA)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            autoGrant(Manifest.permission.POST_NOTIFICATIONS)
        }

        // Own the HOME intent: neutralises the HOME key and gives free
        // auto-start at boot without relying on BOOT_COMPLETED timing.
        if (config.becomeHomeApp) {
            runCatching {
                val filter = IntentFilter(Intent.ACTION_MAIN).apply {
                    addCategory(Intent.CATEGORY_HOME)
                    addCategory(Intent.CATEGORY_DEFAULT)
                }
                dpm.addPersistentPreferredActivity(
                    admin,
                    filter,
                    ComponentName(appContext, MainActivity::class.java),
                )
            }.onFailure { Log.w(TAG, "addPersistentPreferredActivity failed", it) }
        }

        runCatching { dpm.setUninstallBlocked(admin, appContext.packageName, true) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Blocks "Force stop" and "Clear data" from Settings.
            runCatching {
                dpm.setUserControlDisabledPackages(admin, listOf(appContext.packageName))
            }
        }
        Log.i(TAG, "Device Owner policies applied")
    }

    /** Undo the sticky policies so the device can be handed back / re-flashed. */
    fun clearDeviceOwnerPolicies() {
        if (!isDeviceOwner) return
        runCatching { dpm.setStatusBarDisabled(admin, false) }
        runCatching { dpm.setKeyguardDisabled(admin, false) }
        runCatching { dpm.setUninstallBlocked(admin, appContext.packageName, false) }
        runCatching { dpm.clearPackagePersistentPreferredActivities(admin, appContext.packageName) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            runCatching { dpm.setUserControlDisabledPackages(admin, emptyList()) }
        }
        runCatching { dpm.setLockTaskPackages(admin, emptyArray()) }
    }

    private fun autoGrant(permission: String) {
        runCatching {
            dpm.setPermissionGrantState(
                admin,
                appContext.packageName,
                permission,
                DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED,
            )
        }.onFailure { Log.w(TAG, "Auto-grant of $permission failed", it) }
    }

    // ---------------------------------------------------------------------
    // Hardware keys
    // ---------------------------------------------------------------------

    /**
     * Returns true when MainActivity should swallow the key.
     *
     * HOME and POWER never reach an app - only Lock Task / being the Home app
     * neutralises those. Volume is deliberately left alone so an operator can
     * still mute a noisy dashboard.
     */
    fun shouldConsumeKey(keyCode: Int): Boolean {
        if (!config.blockHardwareKeys) return false
        return when (keyCode) {
            KeyEvent.KEYCODE_BACK,
            KeyEvent.KEYCODE_MENU,
            KeyEvent.KEYCODE_SEARCH,
            KeyEvent.KEYCODE_APP_SWITCH,
            KeyEvent.KEYCODE_ASSIST,
            KeyEvent.KEYCODE_VOICE_ASSIST,
            KeyEvent.KEYCODE_SETTINGS,
            KeyEvent.KEYCODE_NOTIFICATION,
            KeyEvent.KEYCODE_SYSRQ,
            -> true

            else -> false
        }
    }

    // ---------------------------------------------------------------------
    // Misc
    // ---------------------------------------------------------------------

    /** Handles the `bring_to_foreground` remote command. */
    fun bringToForeground(): Boolean {
        val intent = Intent(appContext, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }
        return try {
            appContext.startActivity(intent)
            true
        } catch (e: Exception) {
            // Background activity starts are blocked from Android 10 unless the
            // app is Device Owner, the Home app, or holds SYSTEM_ALERT_WINDOW.
            Log.e(TAG, "bringToForeground blocked", e)
            false
        }
    }

    /** Intent that opens the system "activate device admin" consent screen. */
    fun adminActivationIntent(): Intent =
        Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
            putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, admin)
            putExtra(
                DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                "Aura Display needs device admin rights to lock the screen and " +
                    "keep the dashboard pinned.",
            )
        }

    private fun syncTouchShield() {
        // Only needed as a Device Owner fallback: with policy in force the
        // shade is already gone and an extra overlay just eats touches.
        val wanted = config.blockStatusBar && !isDeviceOwner
        if (wanted) barBlocker.show() else barBlocker.hide()
    }

    private fun isDefaultHomeApp(): Boolean {
        val resolved = appContext.packageManager.resolveActivity(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
            android.content.pm.PackageManager.MATCH_DEFAULT_ONLY,
        )
        return resolved?.activityInfo?.packageName == appContext.packageName
    }

    private companion object {
        const val TAG = "AuraKioskManager"
    }
}
