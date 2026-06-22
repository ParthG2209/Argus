package com.argus.client

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger

/**
 * Hardware H.264 decoder driving a Surface directly (no CPU copies).
 * Runs MediaCodec in asynchronous mode. Frames are length-prefixed Annex B
 * access units (SPS/PPS inlined on keyframes) pushed via [submitFrame].
 */
class VideoDecoder(
    private val surface: Surface,
    private val width: Int = 2732,
    private val height: Int = 2048,
) {
    private var codec: MediaCodec? = null
    private val pendingFrames = LinkedBlockingQueue<ByteArray>(120)
    private val renderedCounter = AtomicInteger(0)

    @Volatile var onFirstFrame: (() -> Unit)? = null
    private var sawFirstFrame = false

    /** Number of frames rendered since the last call; resets the counter. */
    fun takeRenderedCount(): Int = renderedCounter.getAndSet(0)

    fun start() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            // Generous max input size for large keyframes.
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
        }

        val mc = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        mc.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(c: MediaCodec, index: Int) {
                feedInput(c, index)
            }

            override fun onOutputBufferAvailable(
                c: MediaCodec, index: Int, info: MediaCodec.BufferInfo
            ) {
                // Render directly to the Surface.
                c.releaseOutputBuffer(index, true)
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
                Log.i(TAG, "Output format changed: $format")
            }
        })
        mc.configure(format, surface, null, 0)
        mc.start()
        codec = mc
        Log.i(TAG, "VideoDecoder started ${width}x${height}")
    }

    private fun feedInput(c: MediaCodec, index: Int) {
        val frame = pendingFrames.poll() ?: run {
            // No data yet — re-queue a tiny empty wait by submitting nothing.
            // Hold the buffer index briefly by submitting an empty buffer is
            // not allowed; instead stash the index for the next frame.
            stashInputIndex(c, index)
            return
        }
        val input: ByteBuffer? = c.getInputBuffer(index)
        if (input == null) {
            // Drop frame if buffer vanished.
            return
        }
        input.clear()
        input.put(frame)
        c.queueInputBuffer(index, 0, frame.size, computePts(), 0)
    }

    // Simple ring of free input indices when no frame is ready.
    private val freeInputIndices = LinkedBlockingQueue<Int>(64)
    private fun stashInputIndex(c: MediaCodec, index: Int) {
        // Try to immediately reuse if a frame raced in.
        val frame = pendingFrames.poll()
        if (frame != null) {
            val input = c.getInputBuffer(index) ?: return
            input.clear(); input.put(frame)
            c.queueInputBuffer(index, 0, frame.size, computePts(), 0)
        } else {
            freeInputIndices.offer(index)
        }
    }

    private var ptsUs = 0L
    private fun computePts(): Long {
        ptsUs += 16_666 // ~60fps spacing; decode order only, surface renders on output
        return ptsUs
    }

    /** Push a decoded-ready Annex B access unit. */
    fun submitFrame(frame: ByteArray) {
        // If a buffer was waiting, fill it now.
        val idx = freeInputIndices.poll()
        val c = codec
        if (idx != null && c != null) {
            val input = c.getInputBuffer(idx)
            if (input != null) {
                input.clear(); input.put(frame)
                c.queueInputBuffer(idx, 0, frame.size, computePts(), 0)
                return
            }
        }
        if (!pendingFrames.offer(frame)) {
            // Queue full — drop oldest to keep latency low.
            pendingFrames.poll()
            pendingFrames.offer(frame)
        }
    }

    fun stop() {
        try {
            codec?.stop()
            codec?.release()
        } catch (e: Exception) {
            Log.w(TAG, "stop: ${e.message}")
        }
        codec = null
        pendingFrames.clear()
        freeInputIndices.clear()
    }

    companion object {
        private const val TAG = "ArgusVideo"
    }
}
