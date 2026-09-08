package com.auradisplay.kiosk.vision

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.lifecycle.LifecycleOwner
import com.auradisplay.kiosk.AuraConfig
import com.auradisplay.kiosk.AuraCore
import kotlin.math.abs

/**
 * Fuses the camera and ambient sources into one presence signal, and owns the
 * wake decision.
 *
 * The wake decision lives here - in native code - on purpose. When the display
 * is off the Dart isolate may not be scheduled promptly, and routing
 * motion -> Dart -> platform channel -> screen-on would add unbounded latency
 * to the one interaction users judge a kiosk on. Dart is *told* about motion so
 * it can publish to MQTT; it is not in the critical path.
 *
 * Event shape is edge-triggered (`detected: true` then `detected: false`),
 * which maps directly onto a Home Assistant `binary_sensor`.
 */
class MotionCoordinator(context: Context) {

    private val engine = MotionDetectionEngine(context)
    private val sensors = AmbientSensorSource(context)
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var config: AuraConfig = AuraConfig()

    private var owner: LifecycleOwner? = null
    private var clearTask: Runnable? = null

    @Volatile
    var isMotionActive: Boolean = false
        private set

    private var lastTriggerAt = 0L
    private var lastWakeAt = 0L

    @Volatile
    private var lastSource: String? = null

    init {
        engine.listener = MotionDetectionEngine.Listener { sample -> onCameraSample(sample) }
        sensors.listener = AmbientSensorSource.Listener { source, value ->
            trigger(source, mapOf("value" to value))
        }
    }

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /** @param owner the foreground service - analysis must outlive the Activity. */
    fun start(owner: LifecycleOwner) {
        this.owner = owner
        syncSources()
    }

    fun stop() {
        engine.stop()
        sensors.stop()
        cancelClear()
        isMotionActive = false
        owner = null
    }

    fun shutdown() {
        cancelClear()
        sensors.stop()
        engine.shutdown()
        owner = null
    }

    fun updateConfig(next: AuraConfig) {
        config = next
        engine.updateTuning(MotionTuning.fromSensitivity(next.motionSensitivity, next.motionAnalysisFps))
        sensors.updateTuning(next.luxTriggerDelta)
        syncSources()
    }

    fun state(): Map<String, Any?> = mapOf(
        "motionDetected" to isMotionActive,
        "motionEnabled" to config.motionEnabled,
        "motionSource" to config.motionSource,
        "cameraRunning" to engine.isRunning,
        "sensorsRunning" to sensors.isRunning,
        "cameraPermission" to engine.hasCameraPermission,
        "sensorsAvailable" to sensors.available,
        "illuminance" to sensors.currentLux.takeIf { it >= 0f },
        "lastError" to engine.lastError,
        "lastTriggerSource" to lastSource,
        "msSinceLastTrigger" to
            if (lastTriggerAt == 0L) null else SystemClock.elapsedRealtime() - lastTriggerAt,
    )

    /** True when the service must declare FOREGROUND_SERVICE_TYPE_CAMERA. */
    val needsCameraServiceType: Boolean get() = config.cameraRequested

    // ---------------------------------------------------------------------
    // Source management
    // ---------------------------------------------------------------------

    private fun syncSources() {
        val cfg = config
        val o = owner ?: return

        if (cfg.cameraRequested) {
            engine.start(
                o,
                MotionTuning.fromSensitivity(cfg.motionSensitivity, cfg.motionAnalysisFps),
            ) { error ->
                if (error != null) {
                    AuraCore.emit(EVENT_MOTION_STATE, state() + mapOf("error" to error))
                    // Camera unavailable is not fatal: fall back to sensors so
                    // the display still wakes on presence.
                    if (sensors.available && !sensors.isRunning) sensors.start(cfg.luxTriggerDelta)
                } else {
                    AuraCore.emit(EVENT_MOTION_STATE, state())
                }
            }
        } else if (engine.isRunning) {
            engine.stop()
        }

        if (cfg.sensorsRequested) {
            if (!sensors.isRunning) sensors.start(cfg.luxTriggerDelta)
        } else if (sensors.isRunning && !cfg.cameraRequested) {
            sensors.stop()
        }
    }

    // ---------------------------------------------------------------------
    // Signal handling
    // ---------------------------------------------------------------------

    private fun onCameraSample(sample: MotionSample) {
        // A large uniform luma jump is not "motion" by the local-change test,
        // but on a wall display it almost always means someone switched the
        // room light on - which is exactly when the dashboard should wake.
        val illuminationJump = abs(sample.globalLumaShift) >= ILLUMINATION_JUMP

        if (!sample.motion && !illuminationJump) return

        trigger(
            if (sample.motion) "camera" else "illumination",
            mapOf(
                "changedFraction" to sample.changedFraction,
                "peakDelta" to sample.peakDelta,
                "meanLuma" to sample.meanLuma,
                "globalLumaShift" to sample.globalLumaShift,
            ),
        )
    }

    private fun trigger(source: String, detail: Map<String, Any?>) {
        val cfg = config
        if (!cfg.motionEnabled) return

        val now = SystemClock.elapsedRealtime()
        lastTriggerAt = now
        lastSource = source
        val risingEdge = !isMotionActive
        isMotionActive = true
        scheduleClear(cfg.motionClearAfterMs)

        if (cfg.wakeOnMotion && AuraCore.isInitialized) {
            // Keep an already-lit display awake. Outside the cooldown on
            // purpose: the cooldown exists to stop a busy room thrashing the
            // backlight, and must not also decide how long the panel stays up.
            // Inside it, a cooldown longer than screenTimeoutSeconds would let
            // the display sleep with someone standing in front of it.
            AuraCore.screen.notePresence()

            // Wake first, report second. Cooldown rate-limits the wake, not the
            // detection, so a busy room does not thrash the backlight.
            if (now - lastWakeAt >= cfg.motionCooldownMs) {
                lastWakeAt = now
                if (!AuraCore.screen.isScreenOn) {
                    AuraCore.screen.wake("motion:$source")
                }
            }
        }

        if (risingEdge) {
            Log.i(TAG, "Motion detected via $source $detail")
            AuraCore.emit(
                EVENT_MOTION,
                mapOf("detected" to true, "source" to source) + detail,
            )
        }
    }

    private fun scheduleClear(afterMs: Long) {
        cancelClear()
        val task = Runnable {
            if (!isMotionActive) return@Runnable
            isMotionActive = false
            AuraCore.emit(EVENT_MOTION, mapOf("detected" to false, "source" to lastSource))
        }
        clearTask = task
        main.postDelayed(task, afterMs.coerceAtLeast(1_000L))
    }

    private fun cancelClear() {
        clearTask?.let { main.removeCallbacks(it) }
        clearTask = null
    }

    private companion object {
        const val TAG = "AuraMotion"
        const val EVENT_MOTION = "motion"
        const val EVENT_MOTION_STATE = "motionState"

        /** Mean luma delta (0..255) that reads as "the lights just changed". */
        const val ILLUMINATION_JUMP = 18
    }
}
