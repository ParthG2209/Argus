package com.argus.client

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Owns the three socket connections, with retry-every-2s reconnection. If any
 * socket drops, all three are torn down and re-established together.
 */
class ConnectionManager(
    private val videoDecoder: VideoDecoder,
    private val audioPlayer: AudioPlayer,
    private val inputForwarder: InputForwarder,
    private val screenWidth: Int,
    private val screenHeight: Int,
    private val screenRefresh: Int,
) {
    enum class Status { DISCONNECTED, CONNECTED, STREAMING }

    @Volatile var onStatus: ((Status) -> Unit)? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var sessionJob: Job? = null
    @Volatile private var active = false

    fun start() {
        if (active) return
        active = true
        videoDecoder.onFirstFrame = { onStatus?.invoke(Status.STREAMING) }
        sessionJob = scope.launch { reconnectLoop() }
    }

    fun stop() {
        active = false
        sessionJob?.cancel()
        sessionJob = null
        onStatus?.invoke(Status.DISCONNECTED)
    }

    private suspend fun reconnectLoop() {
        while (active) {
            onStatus?.invoke(Status.DISCONNECTED)
            var video: Socket? = null
            var input: Socket? = null
            var audio: Socket? = null
            try {
                video = connect(Protocol.PORT_VIDEO)
                input = connect(Protocol.PORT_INPUT)
                audio = connect(Protocol.PORT_AUDIO)

                // Report our real resolution FIRST so the Mac sizes the
                // virtual display to match (newline-terminated JSON).
                val out = input.getOutputStream()
                val hello = "{\"type\":\"hello\",\"width\":$screenWidth,\"height\":$screenHeight," +
                    "\"refresh\":$screenRefresh}\n"
                out.write(hello.toByteArray(Charsets.UTF_8)); out.flush()
                inputForwarder.setOutput(out)
                onStatus?.invoke(Status.CONNECTED)
                Log.i(TAG, "All sockets connected. Sent hello ${screenWidth}x${screenHeight}@${screenRefresh}")

                coroutineScope {
                    val videoJob = launch { readVideo(video!!) }
                    val audioJob = launch { readAudio(audio!!) }
                    // Video EOF is the primary disconnect signal.
                    videoJob.join()
                    audioJob.cancel()
                }
            } catch (e: Exception) {
                Log.w(TAG, "session ended: ${e.message}")
            } finally {
                inputForwarder.setOutput(null)
                closeQuietly(video); closeQuietly(input); closeQuietly(audio)
            }
            if (active) {
                onStatus?.invoke(Status.DISCONNECTED)
                delay(2000)
            }
        }
    }

    private fun connect(port: Int): Socket {
        val s = Socket()
        s.tcpNoDelay = true
        s.connect(InetSocketAddress(Protocol.HOST, port), 3000)
        Log.i(TAG, "Connected to $port")
        return s
    }

    private suspend fun readVideo(socket: Socket) {
        val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 1 shl 20))

        // The first frame is a codec handshake (['A','R','G', codecByte]).
        val first = readFrame(input) ?: return
        val mime = Handshake.mimeOrNull(first)
        try {
            if (mime != null) {
                Log.i(TAG, "Codec handshake: $mime — starting decoder")
                videoDecoder.start(mime)
            } else {
                Log.i(TAG, "No handshake; assuming H.264")
                videoDecoder.start(Protocol.MIME_H264)
                if (first.size > 8) {
                    videoDecoder.submitFrame(first, 8, first.size - 8, readBE64(first, 0))
                }
            }
        } catch (e: Exception) {
            // Most likely: this device's decoder can't handle the codec/size.
            Log.e(TAG, "DECODER START FAILED for $mime: ${e.message}", e)
            throw e
        }

        var count = 0
        var bytes = 0L
        while (scope.isActive && active) {
            val frame = readFrame(input) ?: break
            // Each frame = [8-byte BE capture-µs][Annex B NAL].
            if (frame.size <= 8) continue
            val ptsUs = readBE64(frame, 0)
            videoDecoder.submitFrame(frame, 8, frame.size - 8, ptsUs)
            count++; bytes += frame.size
            if (count <= 3 || count % 240 == 0) {
                Log.i(TAG, "video frames received=$count, lastSize=${frame.size}, total=${bytes}B")
            }
        }
        Log.i(TAG, "Video stream ended.")
    }

    private suspend fun readAudio(socket: Socket) {
        val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 1 shl 16))
        while (scope.isActive && active) {
            val frame = readFrame(input) ?: break
            audioPlayer.submitFrame(frame)
        }
        Log.i(TAG, "Audio stream ended.")
    }

    private fun closeQuietly(s: Socket?) {
        try { s?.close() } catch (_: Exception) {}
    }

    companion object {
        private const val TAG = "ArgusNet"
    }
}
