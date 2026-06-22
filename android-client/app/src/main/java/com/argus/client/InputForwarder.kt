package com.argus.client

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import java.io.OutputStream
import java.util.concurrent.Executors

/**
 * Serializes input batches to JSON and writes them to the input socket
 * (port 7176) on a dedicated single-thread dispatcher, so high-frequency
 * stylus traffic never blocks the video decode pipeline.
 *
 * Rate limiting:
 *   - finger MOVE: 120 msgs/sec
 *   - stylus/eraser MOVE: unthrottled
 *   - hover: 60 msgs/sec
 *   - down/up/button_*: never dropped
 */
class InputForwarder {
    private val dispatcher = Executors.newSingleThreadExecutor { r ->
        Thread(r, "argus-input").apply { priority = Thread.MAX_PRIORITY }
    }.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val channel = Channel<String>(capacity = 256)

    @Volatile private var output: OutputStream? = null

    // Rate-limit bookkeeping (nanos).
    private var lastFingerMoveNs = 0L
    private var lastHoverNs = 0L
    private val fingerMoveIntervalNs = 1_000_000_000L / 120
    private val hoverIntervalNs = 1_000_000_000L / 60

    init {
        scope.launch {
            for (line in channel) {
                try {
                    val out = output ?: continue
                    out.write(line.toByteArray(Charsets.UTF_8))
                    out.flush()
                } catch (e: Exception) {
                    Log.w(TAG, "input write failed: ${e.message}")
                }
            }
        }
    }

    fun setOutput(stream: OutputStream?) {
        output = stream
    }

    /** Enqueue a batch, applying the rate-limit policy. */
    fun send(batch: InputBatch) {
        if (shouldDrop(batch)) return
        val line = batch.toJsonLine()
        val result = channel.trySend(line)
        if (result.isFailure) {
            Log.v(TAG, "input channel full; dropped ${batch.action}")
        }
    }

    private fun shouldDrop(batch: InputBatch): Boolean {
        val now = System.nanoTime()
        return when (batch.action) {
            "move" -> {
                if (batch.toolType == "finger") {
                    if (now - lastFingerMoveNs < fingerMoveIntervalNs) true
                    else { lastFingerMoveNs = now; false }
                } else {
                    false // stylus/eraser: never throttle
                }
            }
            "hover" -> {
                if (now - lastHoverNs < hoverIntervalNs) true
                else { lastHoverNs = now; false }
            }
            else -> false // down/up/button_* always sent
        }
    }

    fun close() {
        channel.close()
        dispatcher.close()
    }

    companion object {
        private const val TAG = "ArgusInput"
    }
}
