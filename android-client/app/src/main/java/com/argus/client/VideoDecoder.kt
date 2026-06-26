package com.argus.client

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Hardware video decoder driving a Surface directly (no CPU copies), in
 * MediaCodec asynchronous mode. Frames are length-prefixed Annex B access
 * units (SPS/PPS inlined on keyframes), each carrying the Mac's capture
 * timestamp (µs) via [submitFrame].
 *
 * Frame presentation: each decoded frame is immediately released to the
 * Surface with `releaseOutputBuffer(index, true)`, which snaps it to the
 * very next VSync boundary. This gives the lowest possible latency and
 * guarantees every frame is perfectly VSync-aligned — matching how native
 * Android apps render.
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
    private val isRunning = AtomicBoolean(true)
    private val renderedCount = AtomicInteger(0)

    private val jitterAccUs = AtomicLong(0)
    private val deltaCount = AtomicInteger(0)
    @Volatile var onFirstFrame: (() -> Unit)? = null
    private var sawFirstFrame = false

    // Jitter measurement: track cycle-to-cycle variance in Mac capture
    // timestamps so the HUD can display frame-pacing quality.
    private var lastPtsUs = 0L
    private var lastDeltaUs = 0L

    private class PendingFrame(val data: ByteArray, val offset: Int, val length: Int, val ptsUs: Long)

    fun takeRenderedCount(): Int = renderedCount.getAndSet(0)

    fun takeJitterMs(): Float {
        val count = deltaCount.getAndSet(0)
        val acc = jitterAccUs.getAndSet(0)
        if (count == 0) return 0f
        return (acc.toFloat() / count) / 1000f
    }

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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                setInteger(MediaFormat.KEY_PRIORITY, 0)
                setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
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
                // Present at the very next VSync — lowest latency, perfect
                // VSync alignment, just like native Android rendering.
                c.releaseOutputBuffer(index, true)
                renderedCount.incrementAndGet()
                if (!sawFirstFrame) {
                    sawFirstFrame = true
                    onFirstFrame?.invoke()
                }

                // Jitter measurement (Mac-side frame spacing).
                if (lastPtsUs > 0L) {
                    val deltaUs = info.presentationTimeUs - lastPtsUs
                    if (lastDeltaUs > 0L) {
                        val jitter = Math.abs(deltaUs - lastDeltaUs)
                        jitterAccUs.addAndGet(jitter)
                        deltaCount.incrementAndGet()
                    }
                    lastDeltaUs = deltaUs
                }
                lastPtsUs = info.presentationTimeUs
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
        lastPtsUs = 0L
        lastDeltaUs = 0L
        synchronized(lock) {
            pendingFrames.clear()
            availableInputs.clear()
        }
    }

    companion object {
        private const val TAG = "ArgusVideo"
    }
}
