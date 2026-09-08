package com.auradisplay.kiosk

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.util.Log
import com.auradisplay.kiosk.service.AuraKioskService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The single seam between Dart and native.
 *
 * Two channels, one direction each:
 *  - `aura/commands` (MethodChannel): Dart -> native imperative calls.
 *  - `aura/events`   (EventChannel):  native -> Dart notifications
 *    (motion edges, screen-state changes, kiosk status changes).
 *
 * Keeping the whole surface in one file is intentional: it is the contract, and
 * a contract you have to grep for is a contract that drifts. Once it stabilises
 * this is the natural place to switch to Pigeon for compile-time type safety on
 * both sides - see ARCHITECTURE.md.
 */
class AuraChannels(private val host: Activity) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    fun attachTo(messenger: BinaryMessenger) {
        AuraCore.ensureInitialized(host)
        methodChannel = MethodChannel(messenger, CHANNEL_COMMANDS).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(messenger, CHANNEL_EVENTS).also {
            it.setStreamHandler(this)
        }
    }

    fun detach() {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        AuraCore.eventSink = null
    }

    // ---------------------------------------------------------------------
    // EventChannel
    // ---------------------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        AuraCore.eventSink = { payload -> events?.success(payload) }
        // Prime Dart with the current truth so it never has to guess.
        AuraCore.emit("ready", snapshot())
    }

    override fun onCancel(arguments: Any?) {
        AuraCore.eventSink = null
    }

    // ---------------------------------------------------------------------
    // MethodChannel
    // ---------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // --- state -------------------------------------------------
                "getStatus" -> result.success(snapshot())

                "pushConfig" -> {
                    val config = AuraConfig.fromMap(call.arguments as? Map<*, *>)
                    AuraCore.updateConfig(config)
                    result.success(snapshot())
                }

                // --- kiosk -------------------------------------------------
                "engageKiosk" -> result.success(AuraCore.kiosk.engage())
                "releaseKiosk" -> {
                    AuraCore.kiosk.release()
                    result.success(AuraCore.kiosk.status())
                }
                "startLockTask" -> result.success(AuraCore.kiosk.startLockTask())
                "stopLockTask" -> result.success(AuraCore.kiosk.stopLockTask())
                "applyDeviceOwnerPolicies" -> {
                    AuraCore.kiosk.applyDeviceOwnerPolicies()
                    result.success(AuraCore.kiosk.status())
                }
                "clearDeviceOwnerPolicies" -> {
                    AuraCore.kiosk.clearDeviceOwnerPolicies()
                    result.success(AuraCore.kiosk.status())
                }
                "bringToForeground" -> result.success(AuraCore.kiosk.bringToForeground())

                // --- display ------------------------------------------------
                "setScreen" -> {
                    val on = call.argument<Boolean>("on") ?: true
                    result.success(AuraCore.screen.setScreen(on, "remote"))
                }
                "setBrightness" -> {
                    val value = call.argument<Int>("value") ?: 255
                    result.success(AuraCore.screen.setBrightness(value))
                }
                "noteInteraction" -> {
                    AuraCore.screen.noteInteraction()
                    result.success(true)
                }

                // --- service ------------------------------------------------
                "startService" -> {
                    AuraKioskService.start(host)
                    result.success(true)
                }
                "stopService" -> {
                    AuraKioskService.stop(host)
                    result.success(true)
                }

                // --- permission / settings escape hatches -------------------
                "openAdminActivation" -> {
                    host.startActivity(AuraCore.kiosk.adminActivationIntent())
                    result.success(true)
                }
                "openOverlaySettings" -> {
                    host.startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:${host.packageName}"),
                        ),
                    )
                    result.success(true)
                }
                "openWriteSettings" -> {
                    host.startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_WRITE_SETTINGS,
                            Uri.parse("package:${host.packageName}"),
                        ),
                    )
                    result.success(true)
                }
                "openHomeAppSettings" -> {
                    host.startActivity(Intent(Settings.ACTION_HOME_SETTINGS))
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Channel call ${call.method} failed", t)
            result.error("aura_error", t.message, t.stackTraceToString())
        }
    }

    /** Everything Dart needs to render the admin panel and publish telemetry. */
    private fun snapshot(): Map<String, Any?> =
        AuraCore.kiosk.status() + AuraCore.screen.state() + AuraCore.motion.state()

    companion object {
        private const val TAG = "AuraChannels"
        const val CHANNEL_COMMANDS = "aura/commands"
        const val CHANNEL_EVENTS = "aura/events"
    }
}
