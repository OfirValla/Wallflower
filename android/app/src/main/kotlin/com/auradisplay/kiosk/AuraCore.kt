package com.auradisplay.kiosk

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.auradisplay.kiosk.kiosk.KioskManager
import com.auradisplay.kiosk.power.ScreenController
import com.auradisplay.kiosk.vision.MotionCoordinator

/**
 * Process-wide holder for the native managers.
 *
 * A Flutter app has two independent entry points into native code - the
 * Activity (`MainActivity`) and the foreground service (`AuraKioskService`) -
 * and both need the *same* [KioskManager] and [ScreenController] instances.
 * A plain object is the right tool here; wiring a DI container into a Flutter
 * Android host buys nothing.
 *
 * All state mutation happens on the main thread; [emit] marshals for callers
 * that are on a camera or sensor thread.
 */
object AuraCore {

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var initialized = false

    lateinit var kiosk: KioskManager
        private set

    lateinit var screen: ScreenController
        private set

    lateinit var motion: MotionCoordinator
        private set

    @Volatile
    var config: AuraConfig = AuraConfig()
        private set

    /**
     * Set by [AuraChannels] while the EventChannel is listened to. Null while
     * the Flutter engine is detached - events are then simply dropped, which is
     * correct: native already acted on them (e.g. woke the display) and Dart
     * will re-read state on reattach.
     */
    @Volatile
    var eventSink: ((Map<String, Any?>) -> Unit)? = null

    @Synchronized
    fun ensureInitialized(context: Context): AuraCore {
        if (!initialized) {
            val app = context.applicationContext
            kiosk = KioskManager(app)
            screen = ScreenController(app)
            motion = MotionCoordinator(app)
            initialized = true
        }
        return this
    }

    val isInitialized: Boolean get() = initialized

    fun updateConfig(next: AuraConfig) {
        config = next
        if (!initialized) return
        kiosk.updateConfig(next)
        screen.updateConfig(next)
        motion.updateConfig(next)
    }

    /** Fire-and-forget event to Dart. Safe from any thread. */
    fun emit(type: String, data: Map<String, Any?> = emptyMap()) {
        val payload = HashMap<String, Any?>(data.size + 2)
        payload["type"] = type
        payload["at"] = System.currentTimeMillis()
        payload.putAll(data)
        main.post { eventSink?.invoke(payload) }
    }
}
