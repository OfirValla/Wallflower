package com.auradisplay.kiosk

/**
 * The slice of settings the native layer needs.
 *
 * Dart owns the full [AuraSettings] model and persistence; it pushes this
 * subset down through `MethodChannel("aura/commands").invokeMethod("pushConfig")`
 * whenever it changes. Keeping the native config small and explicit means the
 * service can behave correctly even if the Dart isolate is never scheduled -
 * which is exactly the case while the display is off.
 */
data class AuraConfig(
    // --- Lockdown ---------------------------------------------------------
    val kioskEnabled: Boolean = true,
    val lockTaskEnabled: Boolean = true,
    val immersive: Boolean = true,
    val blockStatusBar: Boolean = true,
    val blockHardwareKeys: Boolean = true,
    val dismissKeyguard: Boolean = true,
    val allowPowerMenu: Boolean = false,
    val becomeHomeApp: Boolean = true,

    // --- Display / power --------------------------------------------------
    val keepScreenOn: Boolean = true,
    /** "dim" = black overlay + 0% backlight (instant wake, no keyguard).
     *  "deviceLock" = DevicePolicyManager.lockNow() (real panel off). */
    val screenOffMode: String = MODE_DIM,
    /** Seconds of no interaction before the display sleeps. 0 = never. */
    val screenTimeoutSeconds: Int = 0,
    /** 0..255, matching Home Assistant's default light brightness scale. */
    val brightness: Int = 255,
    /** Write Settings.System.SCREEN_BRIGHTNESS instead of window brightness.
     *  Needs WRITE_SETTINGS, granted manually by the operator. */
    val useSystemBrightness: Boolean = false,

    // --- Motion engine ----------------------------------------------------
    val motionEnabled: Boolean = true,
    /** "camera" | "sensors" | "both" | "none" */
    val motionSource: String = SOURCE_CAMERA,
    /** 0 (least sensitive) .. 100 (most). Mapped in MotionTuning. */
    val motionSensitivity: Int = 50,
    /** Analysis rate cap. 5 fps is plenty for presence and costs ~1% CPU. */
    val motionAnalysisFps: Int = 5,
    /** Suppression window after a motion event, in ms. */
    val motionCooldownMs: Long = 3_000,
    /** How long after the last motion the event is reported as cleared. */
    val motionClearAfterMs: Long = 10_000,
    /** Wake the display natively on motion, without a Dart round trip. */
    val wakeOnMotion: Boolean = true,
    /** Lux delta that counts as an ambient-light trigger. */
    val luxTriggerDelta: Float = 12f,
) {
    companion object {
        const val MODE_DIM = "dim"
        const val MODE_DEVICE_LOCK = "deviceLock"

        const val SOURCE_CAMERA = "camera"
        const val SOURCE_SENSORS = "sensors"
        const val SOURCE_BOTH = "both"
        const val SOURCE_NONE = "none"

        fun fromMap(map: Map<*, *>?): AuraConfig {
            if (map == null) return AuraConfig()
            val d = AuraConfig()

            fun bool(key: String, fallback: Boolean) = map[key] as? Boolean ?: fallback
            fun int(key: String, fallback: Int) = (map[key] as? Number)?.toInt() ?: fallback
            fun long(key: String, fallback: Long) = (map[key] as? Number)?.toLong() ?: fallback
            fun float(key: String, fallback: Float) = (map[key] as? Number)?.toFloat() ?: fallback
            fun str(key: String, fallback: String) = map[key] as? String ?: fallback

            return AuraConfig(
                kioskEnabled = bool("kioskEnabled", d.kioskEnabled),
                lockTaskEnabled = bool("lockTaskEnabled", d.lockTaskEnabled),
                immersive = bool("immersive", d.immersive),
                blockStatusBar = bool("blockStatusBar", d.blockStatusBar),
                blockHardwareKeys = bool("blockHardwareKeys", d.blockHardwareKeys),
                dismissKeyguard = bool("dismissKeyguard", d.dismissKeyguard),
                allowPowerMenu = bool("allowPowerMenu", d.allowPowerMenu),
                becomeHomeApp = bool("becomeHomeApp", d.becomeHomeApp),
                keepScreenOn = bool("keepScreenOn", d.keepScreenOn),
                screenOffMode = str("screenOffMode", d.screenOffMode),
                screenTimeoutSeconds = int("screenTimeoutSeconds", d.screenTimeoutSeconds),
                brightness = int("brightness", d.brightness).coerceIn(0, 255),
                useSystemBrightness = bool("useSystemBrightness", d.useSystemBrightness),
                motionEnabled = bool("motionEnabled", d.motionEnabled),
                motionSource = str("motionSource", d.motionSource),
                motionSensitivity = int("motionSensitivity", d.motionSensitivity).coerceIn(0, 100),
                motionAnalysisFps = int("motionAnalysisFps", d.motionAnalysisFps).coerceIn(1, 15),
                motionCooldownMs = long("motionCooldownMs", d.motionCooldownMs),
                motionClearAfterMs = long("motionClearAfterMs", d.motionClearAfterMs),
                wakeOnMotion = bool("wakeOnMotion", d.wakeOnMotion),
                luxTriggerDelta = float("luxTriggerDelta", d.luxTriggerDelta),
            )
        }
    }

    val cameraRequested: Boolean
        get() = motionEnabled && (motionSource == SOURCE_CAMERA || motionSource == SOURCE_BOTH)

    val sensorsRequested: Boolean
        get() = motionEnabled && (motionSource == SOURCE_SENSORS || motionSource == SOURCE_BOTH)
}
