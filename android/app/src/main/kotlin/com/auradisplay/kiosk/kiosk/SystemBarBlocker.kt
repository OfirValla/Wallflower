package com.auradisplay.kiosk.kiosk

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager

/**
 * Touch shield for the status-bar strip.
 *
 * This is the **fallback** path for devices where Aura is not Device Owner.
 * A Device Owner should call `setStatusBarDisabled(true)` instead - that is a
 * real policy and cannot be defeated. This class only swallows the touch that
 * *starts* the shade pull, by parking a full-width, status-bar-tall overlay
 * window at the top of the screen that returns true from onTouch.
 *
 * Be honest about the limits: it stops a casual downward swipe from the top
 * edge. It does not stop a two-finger shade pull on every OEM skin, and it
 * does nothing about the RECENTS gesture. Ship Device Owner for real lockdown.
 */
class SystemBarBlocker(context: Context) {

    private val appContext = context.applicationContext
    private val windowManager =
        appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private var shield: View? = null

    val isShowing: Boolean get() = shield != null

    /** True when SYSTEM_ALERT_WINDOW has actually been granted. */
    fun canDrawOverlays(): Boolean = Settings.canDrawOverlays(appContext)

    @SuppressLint("ClickableViewAccessibility")
    fun show(): Boolean {
        if (shield != null) return true
        if (!canDrawOverlays()) {
            Log.w(TAG, "SYSTEM_ALERT_WINDOW not granted - cannot install touch shield")
            return false
        }

        // Two status bars tall. The extra height matters because the shade
        // gesture is recognised from a region slightly below the visible bar,
        // and in immersive mode there is no visible bar at all.
        val height = (statusBarHeightPx() * 2).coerceAtLeast(dpToPx(48f))

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            height,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }

        val view = View(appContext).apply {
            setBackgroundColor(Color.TRANSPARENT)
            // Consume everything. Returning true here is the whole point.
            setOnTouchListener { _, _ -> true }
        }

        return try {
            windowManager.addView(view, params)
            shield = view
            Log.i(TAG, "Touch shield installed (${height}px)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add touch shield", e)
            false
        }
    }

    fun hide() {
        val view = shield ?: return
        shield = null
        runCatching { windowManager.removeViewImmediate(view) }
            .onFailure { Log.w(TAG, "Failed to remove touch shield", it) }
    }

    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_SYSTEM_OVERLAY
        }

    private fun statusBarHeightPx(): Int {
        val id = appContext.resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) appContext.resources.getDimensionPixelSize(id) else dpToPx(24f)
    }

    private fun dpToPx(dp: Float): Int =
        (dp * appContext.resources.displayMetrics.density).toInt()

    private companion object {
        const val TAG = "AuraBarBlocker"
    }
}
