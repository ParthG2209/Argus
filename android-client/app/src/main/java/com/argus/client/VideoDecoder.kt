package com.argus.client

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicInteger

/**
 * Hardware video decoder driving a Surface directly (no CPU copies), in
 * MediaCodec asynchronous mode. Frames are length-prefixed Annex B access
 * units (SPS/PPS inlined on keyframes), each carrying the Mac's capture
 * timestamp (µs) via [submitFrame].
 *
 * Frame pacing: the random timing variance of encode + USB + decode is what
 * makes high-fps streams look juddery when frames are shown on arrival. We
 * instead present each frame at its true capture time (mapped into this
 * device's clock, plus a small jitter buffer) using
 * `releaseOutputBuffer(index, renderTimestampNs)`, so the compositor places
 * each frame on the correct vsync — smooth motion at any frame rate.
 */
class VideoDecoder(
    private val surface: Surface,
    private val width: Int = 2732,
    private val height: Int = 2048,
) {
    private var codec: MediaCodec? = null
    private var currentMime: String? = null

    private val lock = Any()
    private val pendingFrames = ArrayDeque<PendingFrame>()  // guarded by lock
    private val availableInputs = ArrayDeque<Int>()         // guarded by lock

    private val renderedCounter = AtomicInteger(0)
    @Volatile var onFirstFrame: (() -> Unit)? = null
    private var sawFirstFrame = false

    // Clock mapping: render frame at (capture - base) + baseRender. The offset
    // (targetOffsetNs) is an ADAPTIVE jitter buffer — it starts tiny for low
    // latency, grows when a frame arrives late (Mac/USB stall), and slowly
    // shrinks back during stable stretches. So latency stays minimal except
    // briefly around real stalls.
    private var baseCaptureUs = 0L
    private var baseRenderNs = 0L
    private var targetOffsetNs = MIN_OFFSET_NS
    private var framesSinceUnderrun = 0
    private var haveBase = false

    private class PendingFrame(val data: ByteArray, val offset: Int, val length: Int, val ptsUs: Long)

    fun takeRenderedCount(): Int = renderedCounter.getAndSet(0)

    fun start(mime: String = Protocol.MIME_H264) {
        if (codec != null) {
            if (currentMime == mime) return
            stop()   // codec changed — tear down and reconfigure
        }
        currentMime = mime

        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
        }

        val mc = MediaCodec.createDecoderByType(mime)
        mc.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(c: MediaCodec, index: Int) {
                val frame: PendingFrame? = synchronized(lock) {
                    pendingFrames.pollFirst().also { if (it == null) availableInputs.addLast(index) }
                }
                if (frame != null) feed(c, index, frame)
            }

            override fun onOutputBufferAvailable(
                c: MediaCodec, index: Int, info: MediaCodec.BufferInfo
            ) {
                // info.presentationTimeUs is the Mac capture time we queued.
                val now = System.nanoTime()
                if (!haveBase) {
                    targetOffsetNs = MIN_OFFSET_NS
                    baseCaptureUs = info.presentationTimeUs
                    baseRenderNs = now + targetOffsetNs
                    framesSinceUnderrun = 0
                    haveBase = true
                }
                var renderNs = baseRenderNs + (info.presentationTimeUs - baseCaptureUs) * 1000L
                val margin = renderNs - now
                if (margin < 0L || margin > MAX_AHEAD_NS) {
                    // Frame arrived late (stall) or clock drifted far: grow the
                    // buffer (only on a real underrun) and resync to now+offset.
                    if (margin < 0L) {
                        targetOffsetNs = minOf(targetOffsetNs + GROW_STEP_NS, MAX_OFFSET_NS)
                    }
                    baseCaptureUs = info.presentationTimeUs
                    baseRenderNs = now + targetOffsetNs
                    renderNs = baseRenderNs
                    framesSinceUnderrun = 0
                } else {
                    framesSinceUnderrun++
                    // Stable for a while → shed accumulated latency a step at a time.
                    if (framesSinceUnderrun >= STABLE_FRAMES && targetOffsetNs > MIN_OFFSET_NS) {
                        val shrink = minOf(SHRINK_STEP_NS, targetOffsetNs - MIN_OFFSET_NS)
                        baseRenderNs -= shrink
                        targetOffsetNs -= shrink
                        renderNs -= shrink
                        framesSinceUnderrun = 0
                    }
                }
                c.releaseOutputBuffer(index, renderNs)   // present at vsync near renderNs
                renderedCounter.incrementAndGet()
                if (!sawFirstFrame) {
                    sawFirstFrame = true
                    onFirstFrame?.invoke()
                }
            }

            override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "MediaCodec error: ${e.message}", e)
            }

            override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {
                Log.i(TAG, "Output format: $format")
            }
        })
        mc.configure(format, surface, null, 0)
        mc.start()
        codec = mc
        Log.i(TAG, "VideoDecoder started ${width}x${height} ($mime)")
    }

    private fun feed(c: MediaCodec, index: Int, frame: PendingFrame) {
        val input = c.getInputBuffer(index) ?: return
        input.clear()
        input.put(frame.data, frame.offset, frame.length)
        c.queueInputBuffer(index, 0, frame.length, frame.ptsUs, 0)
    }

    /**
     * Push one access unit with its Mac capture timestamp (µs). [data] holds
     * the Annex B bytes starting at [offset] for [length] bytes.
     */
    fun submitFrame(data: ByteArray, offset: Int, length: Int, ptsUs: Long) {
        val c = codec ?: return
        val pf = PendingFrame(data, offset, length, ptsUs)
        var feedIndex = -1
        synchronized(lock) {
            val idx = availableInputs.pollFirst()
            if (idx != null) {
                feedIndex = idx
            } else {
                pendingFrames.addLast(pf)
                // Drop oldest to stay current; pacing handles the resulting gap.
                while (pendingFrames.size > MAX_QUEUE) pendingFrames.pollFirst()
            }
        }
        if (feedIndex >= 0) feed(c, feedIndex, pf)
    }

    fun stop() {
        try {
            codec?.stop()
            codec?.release()
        } catch (e: Exception) {
            Log.w(TAG, "stop: ${e.message}")
        }
        codec = null
        currentMime = null
        sawFirstFrame = false
        haveBase = false
        synchronized(lock) {
            pendingFrames.clear()
            availableInputs.clear()
        }
    }

    companion object {
        private const val TAG = "ArgusVideo"
        private const val MAX_QUEUE = 2           // undecoded frames before dropping oldest
        // Adaptive pacing buffer bounds. Starts at MIN (low latency); grows by
        // GROW on a late frame up to MAX; sheds SHRINK after STABLE_FRAMES of
        // no underruns. Net: minimal latency that self-tunes around stalls.
        private const val MIN_OFFSET_NS = 4_000_000L      // ~4ms floor
        private const val MAX_OFFSET_NS = 40_000_000L     // ~40ms ceiling
        private const val GROW_STEP_NS = 6_000_000L       // +6ms per underrun
        private const val SHRINK_STEP_NS = 1_000_000L     // -1ms per stable window
        private const val STABLE_FRAMES = 90              // ~0.8s @110fps between shrinks
        private const val MAX_AHEAD_NS = 60_000_000L      // resync if scheduled >60ms ahead
    }
}
