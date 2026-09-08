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

    /**
     * Last window brightness fraction successfully written, or NaN when
     * unknown.
     *
     * Cleared whenever the Activity changes, because a fresh window starts at
     * BRIGHTNESS_OVERRIDE_NONE no matter what the old one was showing. Without
     * that reset, [reassertBacklight] would skip the write a recreated
     * Activity actually needs.
     */
    @Volatile
    private var appliedFraction: Float = Float.NaN

    /**
     * True once `lockNow()` has been refused, i.e. `deviceLock` mode is really
     * running as `dim`. Sticky: the cause is a missing device-admin activation,
     * which does not change without operator action.
     */
    @Volatile
    private var lockNowDenied: Boolean = false

    /**
     * What the panel should be showing right now.
     *
     * [brightness] is the *configured* level and deliberately survives a
     * sleep; this is the level to actually push. Deriving it in one place is
     * what keeps the backlight and Flutter's black overlay from disagreeing,
     * and a disagreement is visible as a grey, barely-readable dashboard.
     */
    private val desiredBacklight: Int get() = if (isScreenOn) brightness else 0

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------

    fun attach(activity: Activity) {
        activityRef = WeakReference(activity)
        appliedFraction = Float.NaN
        // desiredBacklight, not brightness: if the OS recreated the Activity
        // while the display was logically asleep, lighting the panel to full
        // here would leave a lit screen under Flutter's black overlay.
        applyBrightness(desiredBacklight)
        rearmIdleTimer()
    }

    fun detach(activity: Activity) {
        if (activityRef.get() === activity) {
            activityRef = WeakReference(null)
            appliedFraction = Float.NaN
        }
    }

    /**
     * Re-push the backlight for the current state.
     *
     * Window brightness is written asynchronously on the main thread and can
     * fail or be dropped: no window attached yet, an Activity recreated behind
     * our back, an OEM window manager that resets the override. When that
     * happens during [wake] the result is the worst of both layers - Dart has
     * already been told the screen is on and has faded out its black overlay,
     * while the panel is still at its dimmest. Called from the Activity on
     * resume and on regaining focus, where a window is guaranteed to exist.
     */
    fun reassertBacklight() {
        applyBrightness(desiredBacklight)
    }

    fun updateConfig(next: AuraConfig) {
        val brightnessChanged = next.brightness != config.brightness
        val timeoutChanged = next.screenTimeoutSeconds != config.screenTimeoutSeconds
        config = next
        // Store the new level even while asleep. Guarding this on isScreenOn
        // left `brightness` stale, so the next wake restored the *old* level:
        // dim the panel while it sleeps and the next motion wake brought the
        // previous brightness back.
        if (brightnessChanged) setBrightness(next.brightness)
        if (timeoutChanged) rearmIdleTimer()
    }

    fun state(): Map<String, Any?> = mapOf(
        "screenOn" to isScreenOn,
        // The configured level, which deliberately survives a sleep - Home
        // Assistant's brightness entity should not read 0 just because the
        // panel is dark.
        "brightness" to brightness,
        // What the backlight is meant to be showing. Reported separately so a
        // wake that failed to relight the panel shows up in diagnostics
        // instead of being invisible.
        "backlight" to desiredBacklight,
        // The OS view of things, which can differ from ours in `dim` mode.
        "interactive" to powerManager.isInteractive,
        "screenOffMode" to config.screenOffMode,
        // deviceLock silently degrades to dimming when lockNow() is denied.
        // Reporting the configured mode alone hid that for a long time, so
        // report what is actually in force as well.
        "screenOffModeDegraded" to (
            config.screenOffMode == AuraConfig.MODE_DEVICE_LOCK && lockNowDenied
            ),
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

        // Only a genuinely-off panel needs the wake-lock dance.
        if (config.screenOffMode == AuraConfig.MODE_DEVICE_LOCK &&
            !powerManager.isInteractive
        ) {
            forceDisplayOn()
        }

        // Then relight, in *every* mode. deviceLock is emphatically not exempt:
        // sleep() falls back to dimming whenever lockNow() is denied - which is
        // the norm, since it needs an active device admin - and the device then
        // never leaves the interactive state, so the branch above does nothing
        // and no other path puts the backlight back. The panel sits at its
        // dimmest while Dart is told the screen is on and fades out its black
        // overlay, which reads as a grey, barely-legible dashboard.
        if (!applyBrightness(desiredBacklight)) {
            // Dart is about to drop the overlay regardless, so say plainly that
            // the panel was not relit. onResume/onWindowFocusChanged retries.
            Log.w(TAG, "Woken with no window to relight - backlight deferred")
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
                lockNowDenied = !ok
                if (!ok) {
                    Log.w(TAG, "lockNow() denied - falling back to dim")
                    applyBrightness(desiredBacklight)
                }
            }

            else -> applyBrightness(desiredBacklight)
        }

        Log.i(TAG, "Display slept ($reason)")
        AuraCore.emit(EVENT_SCREEN, state() + mapOf("reason" to reason))
    }

    /** @param value 0..255, matching Home Assistant's light brightness scale. */
    fun setBrightness(value: Int): Boolean {
        brightness = value.coerceIn(0, 255)
        // The derived level keeps a set-brightness-while-asleep from lighting
        // the panel, without losing the value.
        applyBrightness(desiredBacklight)
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

    /**
     * Presence, as distinct from touch: someone is in front of the panel.
     *
     * Pushes the idle timeout out so a display that woke on motion stays awake
     * while they are still there. Without this the timeout counted down from
     * the wake and slept the panel on schedule with someone standing in front
     * of it - only touch fed the timer.
     *
     * Deliberately does *not* wake a sleeping display: that decision and its
     * cooldown belong to MotionCoordinator, and calling this on a dark panel
     * must stay free so presence can be reported unconditionally.
     */
    fun notePresence() {
        if (isScreenOn) rearmIdleTimer()
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /**
     * @return false when there was no window to write to, i.e. the caller's
     *     intent has *not* been carried out and needs re-asserting later. True
     *     only means the write was dispatched; the main-thread write can still
     *     fail, which leaves [appliedFraction] stale on purpose so the next
     *     [reassertBacklight] retries it.
     */
    private fun applyBrightness(value255: Int): Boolean {
        if (config.useSystemBrightness && Settings.System.canWrite(appContext)) {
            applySystemBrightness(value255)
            return true
        }
        // Window-scoped brightness needs no permission and is instant. It only
        // affects our window - which is fine, because in kiosk mode our window
        // is the only thing on screen.
        //
        // 0f is not "backlight off" for an ordinary app window
        // (BRIGHTNESS_OVERRIDE_OFF is system-only), it is the dimmest the panel
        // allows. What makes `dim` mode look off is Flutter's black overlay on
        // top, which is exactly why the two have to stay in agreement.
        val fraction = if (value255 <= 0) 0f else (value255 / 255f).coerceIn(0.004f, 1f)
        val act = activityRef.get() ?: return false
        if (fraction == appliedFraction) return true

        main.post {
            runCatching {
                val attrs: WindowManager.LayoutParams = act.window.attributes
                attrs.screenBrightness = fraction
                act.window.attributes = attrs
                appliedFraction = fraction
            }.onFailure { Log.w(TAG, "Window brightness failed", it) }
        }
        return true
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
        applyBrightness(desiredBacklight)
    }

    private fun rearmIdleTimer() = onMain {
        cancelIdleTimerOnMain()
        val seconds = config.screenTimeoutSeconds
        if (seconds <= 0 || !isScreenOn) return@onMain
        val task = Runnable { sleep("timeout") }
        idleTimer = task
        main.postDelayed(task, seconds * 1_000L)
    }

    private fun cancelIdleTimer() = onMain { cancelIdleTimerOnMain() }

    private fun cancelIdleTimerOnMain() {
        idleTimer?.let { main.removeCallbacks(it) }
        idleTimer = null
    }

    /**
     * Runs [block] on the main thread, inline if already there.
     *
     * [idleTimer] is now touched from three threads - the method channel, the
     * Activity, and the camera analysis thread through [notePresence] at up to
     * the analysis frame rate. Confining every mutation to one thread is what
     * stops a rearm and a cancel from interleaving and leaking a pending
     * `sleep` that fires while someone is still in the room. Posting also keeps
     * ordering: same handler, so a cancel issued before a rearm runs before it.
     */
    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post { block() }
    }

    private companion object {
        const val TAG = "AuraScreen"
        const val EVENT_SCREEN = "screenState"
        const val WAKE_TAG = "AuraDisplay:wake"
        const val WAKE_HOLD_MS = 3_000L
    }
}
