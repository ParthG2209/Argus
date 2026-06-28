package com.argus.client

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer

/**
 * Decodes the incoming raw AAC-LC stream and plays it via AudioTrack.
 * AAC config is derived out-of-band from the fixed 48 kHz / stereo spec.
 */
class AudioPlayer {
    private var track: AudioTrack? = null
    @Volatile private var running = false

    fun start() {
        if (running) return

        val minBuf = AudioTrack.getMinBufferSize(
            Protocol.AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        // Use exactly the minimum buffer size for the lowest possible latency.
        // The hardware fast-mixer path usually requires minBuf.
        val targetBuf = minBuf
        val at = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(Protocol.AUDIO_SAMPLE_RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build()
            )
            .setBufferSizeInBytes(targetBuf)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        at.play()
        track = at
        running = true
        Log.i(TAG, "AudioPlayer started (Raw PCM mode)")
    }

    /** Play one raw PCM frame. */
    fun submitFrame(frame: ByteArray) {
        if (!running) return
        try {
            track?.write(frame, 0, frame.size)
        } catch (e: Exception) {
            Log.w(TAG, "audio playback: ${e.message}")
        }
    }

    fun stop() {
        running = false
        try { track?.stop(); track?.release() } catch (_: Exception) {}
        track = null
    }

    companion object {
        private const val TAG = "AudioPlayer"
    }
}
