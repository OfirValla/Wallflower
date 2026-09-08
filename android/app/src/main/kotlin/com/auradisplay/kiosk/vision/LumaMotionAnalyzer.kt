package com.auradisplay.kiosk.vision

import android.os.SystemClock
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Sensitivity-derived thresholds for [LumaMotionAnalyzer]. */
data class MotionTuning(
    /** Grid is gridSize x gridSize cells. 24 -> 576 cells, a good presence/cost point. */
    val gridSize: Int = 24,
    /** Per-cell luma delta (0..255) that counts as "this cell changed". */
    val cellDeltaThreshold: Int = 12,
    /** Fraction of changed cells that counts as "something moved". */
    val areaFraction: Float = 0.045f,
    /** Hard cap on analysed frames per second. */
    val analysisFps: Int = 5,
) {
    companion object {
        /**
         * Maps a single 0..100 operator-facing "sensitivity" slider onto both
         * thresholds. One knob is all anybody wants to tune on a wall tablet.
         */
        fun fromSensitivity(sensitivity: Int, analysisFps: Int): MotionTuning {
            val s = sensitivity.coerceIn(0, 100) / 100f
            fun lerp(from: Float, to: Float) = from + (to - from) * s
            return MotionTuning(
                gridSize = 24,
                // Insensitive: only large luma swings count. Sensitive: 4/255.
                cellDeltaThreshold = lerp(28f, 4f).roundToInt().coerceAtLeast(2),
                // Insensitive: 18% of the frame must change. Sensitive: 0.8%.
                areaFraction = lerp(0.18f, 0.008f),
                analysisFps = analysisFps.coerceIn(1, 15),
            )
        }
    }
}

/** One analysed frame. Never carries pixel data - only aggregates. */
data class MotionSample(
    val motion: Boolean,
    /** 0..1 share of grid cells that changed beyond the threshold. */
    val changedFraction: Float,
    /** Largest single-cell delta this frame, useful for tuning. */
    val peakDelta: Int,
    /** Mean luma delta across the whole frame: exposure ramps and room lights. */
    val globalLumaShift: Int,
    /** Mean luma 0..255, a rough ambient-brightness proxy. */
    val meanLuma: Int,
)

/**
 * Luma-plane frame differencing.
 *
 * Why not OpenCV or an ML model: this runs 24/7 on a wall-powered tablet whose
 * only job is to notice that a human walked into the room. The Y plane of the
 * YUV_420_888 buffer is *already* a greyscale image - no colour conversion, no
 * copy, no native library, no model warm-up. We downsample it to a 24x24 grid
 * of block means (~9k byte reads per frame), diff against the previous grid and
 * threshold. Measured cost is well under 1% of one core at 5 fps.
 *
 * The one non-obvious trick is subtracting the **global** luma shift before
 * thresholding. Camera auto-exposure constantly ramps the whole frame up and
 * down, and switching on a room light moves every cell at once. Both look
 * identical to naive frame differencing and would fire non-stop. Removing the
 * mean delta leaves only *local* change - i.e. something actually moved - while
 * the global shift is reported separately so an illumination jump can still be
 * treated as its own wake trigger.
 *
 * Frames are never stored, copied off the analysis thread, or exposed to Dart.
 *
 * Thread-safety: [analyze] is only ever called on CameraX's single analysis
 * executor. [tuning] is volatile because the admin panel writes it from main.
 */
internal class LumaMotionAnalyzer(
    private val onSample: (MotionSample) -> Unit,
) : ImageAnalysis.Analyzer {

    @Volatile
    var tuning: MotionTuning = MotionTuning()

    private var current = IntArray(0)
    private var previous = IntArray(0)
    private var hasReference = false
    private var warmupRemaining = 0
    private var lastProcessedAt = 0L

    /** Drop the reference frame, e.g. after the camera rebinds. */
    fun reset() {
        hasReference = false
        warmupRemaining = WARMUP_FRAMES
    }

    override fun analyze(image: ImageProxy) {
        try {
            val t = tuning

            // Rate-limit in the analyzer rather than asking CameraX for a low
            // capture fps: the sensor keeps its preferred rate (better AE) and
            // we simply ignore the frames we do not need.
            val now = SystemClock.elapsedRealtime()
            val minIntervalMs = 1_000L / t.analysisFps.coerceIn(1, 15)
            if (now - lastProcessedAt < minIntervalMs) return
            lastProcessedAt = now

            val cells = t.gridSize
            val total = cells * cells
            if (current.size != total) {
                current = IntArray(total)
                previous = IntArray(total)
                hasReference = false
                warmupRemaining = WARMUP_FRAMES
            }

            sampleLuma(image, cells, current)

            if (!hasReference) {
                current.copyInto(previous)
                hasReference = true
                warmupRemaining = WARMUP_FRAMES
                return
            }

            // Discard the first frames after (re)binding: auto-exposure and
            // auto-white-balance are still settling and would look like motion.
            if (warmupRemaining > 0) {
                warmupRemaining--
                current.copyInto(previous)
                return
            }

            var deltaSum = 0L
            var lumaSum = 0L
            for (i in 0 until total) {
                deltaSum += (current[i] - previous[i]).toLong()
                lumaSum += current[i].toLong()
            }
            val globalShift = (deltaSum / total).toInt()
            val meanLuma = (lumaSum / total).toInt()

            var changed = 0
            var peak = 0
            for (i in 0 until total) {
                val d = abs(current[i] - previous[i] - globalShift)
                if (d > peak) peak = d
                if (d >= t.cellDeltaThreshold) changed++
            }

            val fraction = changed.toFloat() / total
            current.copyInto(previous)

            onSample(
                MotionSample(
                    motion = fraction >= t.areaFraction,
                    changedFraction = fraction,
                    peakDelta = peak,
                    globalLumaShift = globalShift,
                    meanLuma = meanLuma,
                ),
            )
        } finally {
            // Non-negotiable: a leaked ImageProxy stalls the whole pipeline
            // after `imageQueueDepth` frames.
            image.close()
        }
    }

    /**
     * Downsamples plane 0 (luma) into `out` as per-cell means.
     *
     * Handles `rowStride` (row padding is the norm, not the exception) and
     * `pixelStride` (2 on devices that hand back a semi-planar Y plane).
     */
    private fun sampleLuma(image: ImageProxy, cells: Int, out: IntArray) {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val width = image.width
        val height = image.height

        val cellW = max(1, width / cells)
        val cellH = max(1, height / cells)
        // Sample a sparse lattice inside each cell instead of every pixel.
        val stepX = max(1, cellW / SAMPLES_PER_AXIS)
        val stepY = max(1, cellH / SAMPLES_PER_AXIS)

        for (cy in 0 until cells) {
            val yStart = cy * cellH
            val yEnd = min(height, yStart + cellH)
            for (cx in 0 until cells) {
                val xStart = cx * cellW
                val xEnd = min(width, xStart + cellW)

                var sum = 0
                var count = 0
                var y = yStart
                while (y < yEnd) {
                    val rowBase = y * rowStride
                    var x = xStart
                    while (x < xEnd) {
                        // Absolute get: no buffer position mutation, no copy.
                        sum += buffer.get(rowBase + x * pixelStride).toInt() and 0xFF
                        count++
                        x += stepX
                    }
                    y += stepY
                }
                out[cy * cells + cx] = if (count == 0) 0 else sum / count
            }
        }
    }

    private companion object {
        const val SAMPLES_PER_AXIS = 4
        const val WARMUP_FRAMES = 5
    }
}
