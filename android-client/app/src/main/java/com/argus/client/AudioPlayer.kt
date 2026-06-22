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
    private var codec: MediaCodec? = null
    private var track: AudioTrack? = null
    @Volatile private var running = false

    fun start() {
        // AAC-LC csd-0: 5 bits objType(2=LC), 4 bits sampleRateIndex(3=48000),
        // 4 bits channelConfig(2=stereo). => 0x11 0x90
        val csd0 = byteArrayOf(0x11, 0x90.toByte())
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            Protocol.AUDIO_SAMPLE_RATE,
            Protocol.AUDIO_CHANNELS
        ).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE,
                android.media.MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setByteBuffer("csd-0", ByteBuffer.wrap(csd0))
        }

        val mc = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        mc.configure(format, null, null, 0)
        mc.start()
        codec = mc

        val minBuf = AudioTrack.getMinBufferSize(
            Protocol.AUDIO_SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        // ~100ms target buffer, but never below the platform minimum.
        val targetBuf = maxOf(minBuf, Protocol.AUDIO_SAMPLE_RATE * 2 * 2 / 10)
        val at = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
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
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        at.play()
        track = at
        running = true
        Log.i(TAG, "AudioPlayer started")
    }

    /** Decode + play one raw AAC access unit (synchronous decode loop). */
    fun submitFrame(frame: ByteArray) {
        val mc = codec ?: return
        if (!running) return
        try {
            val inIndex = mc.dequeueInputBuffer(10_000)
            if (inIndex >= 0) {
                val buf = mc.getInputBuffer(inIndex)
                buf?.clear()
                buf?.put(frame)
                mc.queueInputBuffer(inIndex, 0, frame.size, 0, 0)
            }
            val info = MediaCodec.BufferInfo()
            var outIndex = mc.dequeueOutputBuffer(info, 0)
            while (outIndex >= 0) {
                val out = mc.getOutputBuffer(outIndex)
                if (out != null && info.size > 0) {
                    val pcm = ByteArray(info.size)
                    out.position(info.offset)
                    out.get(pcm, 0, info.size)
                    track?.write(pcm, 0, pcm.size)
                }
                mc.releaseOutputBuffer(outIndex, false)
                outIndex = mc.dequeueOutputBuffer(info, 0)
            }
        } catch (e: Exception) {
            Log.w(TAG, "audio decode: ${e.message}")
        }
    }

    fun stop() {
        running = false
        try { track?.stop(); track?.release() } catch (_: Exception) {}
        try { codec?.stop(); codec?.release() } catch (_: Exception) {}
        track = null
        codec = null
    }

    companion object {
        private const val TAG = "ArgusAudio"
    }
}
