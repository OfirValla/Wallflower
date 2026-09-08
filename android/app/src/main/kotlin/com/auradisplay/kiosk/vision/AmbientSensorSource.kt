package com.auradisplay.kiosk.vision

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import android.util.Log
import kotlin.math.abs

/**
 * Zero-camera presence fallback: ambient light + proximity.
 *
 * This is the right primary source on devices with no front camera, when the
 * operator refuses camera permission, or on OEM builds that kill camera access
 * while the display is off. It is also a useful supplement to the camera - a
 * hand waved at a wall tablet trips proximity long before it produces enough
 * frame delta to clear the motion threshold.
 *
 * Light triggers on a *departure from the running baseline*, not an absolute
 * level, so it works in a dim hallway and in daylight without retuning. The
 * baseline uses a slow EMA so sunset does not read as a person.
 */
class AmbientSensorSource(context: Context) : SensorEventListener {

    fun interface Listener {
        /**
         * @param source "light" or "proximity"
         * @param value current lux, or 0/1 for proximity near/far
         */
        fun onTrigger(source: String, value: Float)
    }

    private val sensorManager =
        context.applicationContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    private val lightSensor: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_LIGHT)
    private val proximitySensor: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_PROXIMITY)

    var listener: Listener? = null

    @Volatile
    private var luxTriggerDelta: Float = 12f

    @Volatile
    var currentLux: Float = -1f
        private set

    private var luxBaseline = Float.NaN
    private var lastProximityNear: Boolean? = null
    private var lastTriggerAt = 0L

    @Volatile
    var isRunning = false
        private set

    val available: Boolean get() = lightSensor != null || proximitySensor != null

    fun start(luxDelta: Float) {
        luxTriggerDelta = luxDelta
        if (isRunning) return
        // SENSOR_DELAY_NORMAL (~200 ms) is deliberate: presence does not need
        // faster, and faster costs measurable battery on a 24/7 display.
        lightSensor?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        proximitySensor?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        isRunning = lightSensor != null || proximitySensor != null
        Log.i(
            TAG,
            "Ambient sensors started (light=${lightSensor != null}, " +
                "proximity=${proximitySensor != null})",
        )
    }

    fun stop() {
        if (!isRunning) return
        sensorManager.unregisterListener(this)
        isRunning = false
        luxBaseline = Float.NaN
        lastProximityNear = null
    }

    fun updateTuning(luxDelta: Float) {
        luxTriggerDelta = luxDelta
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_LIGHT -> handleLight(event.values[0])
            Sensor.TYPE_PROXIMITY -> handleProximity(event)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun handleLight(lux: Float) {
        currentLux = lux
        if (luxBaseline.isNaN()) {
            luxBaseline = lux
            return
        }
        val delta = abs(lux - luxBaseline)
        // Slow EMA: tracks sunset, ignores a person walking past.
        luxBaseline += (lux - luxBaseline) * BASELINE_ALPHA
        if (delta >= luxTriggerDelta && throttle()) {
            listener?.onTrigger("light", lux)
        }
    }

    private fun handleProximity(event: SensorEvent) {
        val near = event.values[0] < (event.sensor.maximumRange * 0.5f)
        val previous = lastProximityNear
        lastProximityNear = near
        // Fire on transition only, in either direction: approaching the panel
        // and walking away from it are both "somebody is there".
        if (previous != null && previous != near && throttle()) {
            listener?.onTrigger("proximity", if (near) 1f else 0f)
        }
    }

    private fun throttle(): Boolean {
        val now = SystemClock.elapsedRealtime()
        if (now - lastTriggerAt < MIN_TRIGGER_INTERVAL_MS) return false
        lastTriggerAt = now
        return true
    }

    private companion object {
        const val TAG = "AuraAmbient"
        const val BASELINE_ALPHA = 0.02f
        const val MIN_TRIGGER_INTERVAL_MS = 1_500L
    }
}
