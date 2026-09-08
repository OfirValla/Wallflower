package com.auradisplay.kiosk.vision

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CaptureRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import android.util.Size
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory

/**
 * CameraX front-camera motion detection.
 *
 * Design constraints this class exists to satisfy:
 *
 *  - **It must run while the display is off.** That means it is bound to the
 *    foreground service's lifecycle ([androidx.lifecycle.LifecycleService]),
 *    not the Activity's. Binding to the Activity would tear the camera down
 *    exactly when we need it most.
 *  - **It must not cost battery.** No preview use case is bound (nothing is
 *    rendered), analysis resolution is pinned near 640x480, the capture
 *    request asks the sensor for a low AE fps range, and the analyzer itself
 *    hard-caps processing rate.
 *  - **It must never move pixels across a thread boundary.** All analysis
 *    happens on one dedicated below-normal-priority thread; only the small
 *    [MotionSample] aggregate leaves it.
 *
 * Lifecycle: [start] is safe to call repeatedly; it re-tunes instead of
 * rebinding. Everything CameraX-facing is marshalled to the main thread.
 */
class MotionDetectionEngine(context: Context) {

    fun interface Listener {
        fun onSample(sample: MotionSample)
    }

    private val appContext: Context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())

    private val analysisExecutor = Executors.newSingleThreadExecutor(
        ThreadFactory { runnable ->
            Thread(runnable, "aura-motion-analysis").apply {
                // Below normal: the dashboard's rendering always wins.
                priority = Thread.NORM_PRIORITY - 2
                isDaemon = true
            }
        },
    )

    private val analyzer = LumaMotionAnalyzer { sample -> listener?.onSample(sample) }

    private var cameraProvider: ProcessCameraProvider? = null
    private var imageAnalysis: ImageAnalysis? = null

    var listener: Listener? = null

    @Volatile
    var isRunning: Boolean = false
        private set

    @Volatile
    var lastError: String? = null
        private set

    val hasCameraPermission: Boolean
        get() = ContextCompat.checkSelfPermission(appContext, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    fun updateTuning(tuning: MotionTuning) {
        analyzer.tuning = tuning
    }

    /**
     * Binds the analysis use case to [owner].
     *
     * @param owner the foreground service, so analysis outlives the Activity.
     * @param onResult null on success, a human-readable reason on failure.
     */
    fun start(owner: LifecycleOwner, tuning: MotionTuning, onResult: ((String?) -> Unit)? = null) {
        analyzer.tuning = tuning

        if (isRunning) {
            onResult?.invoke(null)
            return
        }
        if (!hasCameraPermission) {
            fail("CAMERA permission not granted", onResult)
            return
        }

        val future = ProcessCameraProvider.getInstance(appContext)
        future.addListener(
            {
                try {
                    bind(future.get(), owner, onResult)
                } catch (t: Throwable) {
                    fail("Camera provider unavailable: ${t.message}", onResult)
                }
            },
            ContextCompat.getMainExecutor(appContext),
        )
    }

    @androidx.annotation.OptIn(markerClass = [ExperimentalCamera2Interop::class])
    private fun bind(
        provider: ProcessCameraProvider,
        owner: LifecycleOwner,
        onResult: ((String?) -> Unit)?,
    ) {
        cameraProvider = provider

        val selector = when {
            provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) ->
                CameraSelector.DEFAULT_FRONT_CAMERA
            // Wall mounts occasionally have the panel rotated; fall back rather
            // than disabling motion detection outright.
            provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) ->
                CameraSelector.DEFAULT_BACK_CAMERA
            else -> {
                fail("No camera on this device", onResult)
                return
            }
        }

        val builder = ImageAnalysis.Builder()
            // Always analyse the newest frame; never queue a backlog.
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
            .setResolutionSelector(
                androidx.camera.core.resolutionselector.ResolutionSelector.Builder()
                    .setResolutionStrategy(
                        androidx.camera.core.resolutionselector.ResolutionStrategy(
                            ANALYSIS_SIZE,
                            androidx.camera.core.resolutionselector.ResolutionStrategy
                                .FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                        ),
                    )
                    .build(),
            )

        // Ask the sensor itself to run slow. This is the single biggest power
        // lever available - it lets the ISP idle between frames instead of
        // producing 30 fps that we then throw away.
        runCatching {
            Camera2Interop.Extender(builder).setCaptureRequestOption(
                CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                Range(SENSOR_FPS_MIN, SENSOR_FPS_MAX),
            )
        }.onFailure { Log.w(TAG, "AE fps range not settable", it) }

        val analysis = builder.build().apply {
            setAnalyzer(analysisExecutor, analyzer)
        }

        try {
            // No Preview use case on purpose: nothing to render, nothing to composite.
            imageAnalysis?.let { provider.unbind(it) }
            provider.bindToLifecycle(owner, selector, analysis)
            imageAnalysis = analysis
            analyzer.reset()
            isRunning = true
            lastError = null
            Log.i(TAG, "Motion analysis bound (${ANALYSIS_SIZE.width}x${ANALYSIS_SIZE.height})")
            onResult?.invoke(null)
        } catch (t: Throwable) {
            // Typically: camera in use by another app, or the OEM blocks camera
            // access while the display is off.
            analysis.clearAnalyzer()
            fail("bindToLifecycle failed: ${t.message}", onResult)
        }
    }

    fun stop() {
        main.post {
            runCatching {
                imageAnalysis?.clearAnalyzer()
                imageAnalysis?.let { cameraProvider?.unbind(it) }
            }.onFailure { Log.w(TAG, "Unbind failed", it) }
            imageAnalysis = null
            isRunning = false
            Log.i(TAG, "Motion analysis stopped")
        }
    }

    /** Call from the service's onDestroy. */
    fun shutdown() {
        stop()
        analysisExecutor.shutdown()
    }

    private fun fail(reason: String, onResult: ((String?) -> Unit)?) {
        isRunning = false
        lastError = reason
        Log.w(TAG, reason)
        onResult?.invoke(reason)
    }

    private companion object {
        const val TAG = "AuraMotionEngine"
        val ANALYSIS_SIZE = Size(640, 480)
        const val SENSOR_FPS_MIN = 5
        const val SENSOR_FPS_MAX = 15
    }
}
