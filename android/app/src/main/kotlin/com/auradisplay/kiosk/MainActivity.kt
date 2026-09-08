package com.auradisplay.kiosk

import android.os.Bundle
import android.view.KeyEvent
import com.auradisplay.kiosk.service.AuraKioskService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The one and only Activity.
 *
 * `singleInstance` + HOME category (see the manifest) means this task is the
 * device's shell. Everything else - the WebView, the black screen-off overlay,
 * the admin panel - is Flutter drawing inside it.
 *
 * The Activity's native job is narrow and lifecycle-shaped: hand itself to the
 * managers that need a Window, re-assert immersive mode every time focus comes
 * back, swallow hardware keys, and start the always-on service now that there
 * is a visible Activity to authorise it.
 */
class MainActivity : FlutterActivity() {

    private var channels: AuraChannels? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AuraCore.ensureInitialized(this)
        channels = AuraChannels(this).also {
            it.attachTo(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AuraCore.ensureInitialized(this)
        AuraCore.kiosk.attach(this)
        AuraCore.screen.attach(this)
    }

    override fun onResume() {
        super.onResume()
        AuraCore.kiosk.applyWindowPolicy(this)
        // Legal here and only here: a foreground service with the `camera` type
        // must be started while an Activity is visible.
        AuraKioskService.start(this)
    }

    /**
     * Immersive mode is not sticky. Any transient system-bar swipe, dialog, or
     * IME leaves the bars up until we hide them again, so this override is what
     * actually keeps the kiosk fullscreen.
     */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) AuraCore.kiosk.applyImmersive(this)
    }

    /** Feeds the display idle timer without Dart having to report every touch. */
    override fun onUserInteraction() {
        super.onUserInteraction()
        if (AuraCore.isInitialized) AuraCore.screen.noteInteraction()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (AuraCore.isInitialized && AuraCore.kiosk.shouldConsumeKey(keyCode)) return true
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (AuraCore.isInitialized && AuraCore.kiosk.shouldConsumeKey(keyCode)) return true
        return super.onKeyUp(keyCode, event)
    }

    /**
     * FlutterActivity routes BACK through its own dispatcher, so `onKeyDown` is
     * not enough on API 33+ with predictive back. Block it here too.
     */
    @Suppress("DEPRECATION", "MissingSuperCall")
    override fun onBackPressed() {
        if (AuraCore.isInitialized && AuraCore.kiosk.shouldConsumeKey(KeyEvent.KEYCODE_BACK)) return
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    override fun onDestroy() {
        channels?.detach()
        channels = null
        if (AuraCore.isInitialized) {
            AuraCore.kiosk.detach(this)
            AuraCore.screen.detach(this)
        }
        super.onDestroy()
    }
}
