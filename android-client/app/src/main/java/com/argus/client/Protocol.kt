package com.argus.client

import java.io.DataInputStream
import java.io.IOException

/**
 * Wire-protocol constants and helpers. Mirrors shared/PROTOCOL.md and the
 * macOS Protocol.swift.
 */
object Protocol {
    const val HOST = "127.0.0.1"
    const val PORT_VIDEO = 7175   // Mac -> Tablet
    const val PORT_INPUT = 7176   // Tablet -> Mac
    const val PORT_AUDIO = 7177   // Mac -> Tablet

    const val AUDIO_SAMPLE_RATE = 48000
    const val AUDIO_CHANNELS = 2

    const val MIME_H264 = "video/avc"
    const val MIME_H265 = "video/hevc"
}

/**
 * The first framed payload on the video socket is a 4-byte handshake:
 * 'A','R','G', codecByte (0 = H.264, 1 = H.265). Real video frames begin with
 * an Annex B start code, never "ARG".
 */
object Handshake {
    private val PREFIX = byteArrayOf(0x41, 0x52, 0x47) // "ARG"

    /** Returns the MediaCodec MIME if [frame] is a handshake, else null. */
    fun mimeOrNull(frame: ByteArray): String? {
        if (frame.size != 4) return null
        if (frame[0] != PREFIX[0] || frame[1] != PREFIX[1] || frame[2] != PREFIX[2]) return null
        return when (frame[3].toInt()) {
            1 -> Protocol.MIME_H265
            else -> Protocol.MIME_H264
        }
    }
}

/** One active pointer in normalized device space. */
data class InputPointer(
    val id: Int,
    val toolType: String,
    val x: Float,
    val y: Float,
    val pressure: Float,
    val tiltX: Float,
    val tiltY: Float,
    val button: String?
)

/** A single frame of input containing all active pointers. */
data class InputFrame(
    val action: String,
    val actionPointerId: Int,
    val timestamp: Long,
    val pointers: List<InputPointer>,
) {
    /** Serialize to the newline-terminated JSON wire form, by hand for speed. */
    fun toJsonLine(): String {
        val sb = StringBuilder(64 + pointers.size * 128)
        sb.append('{')
        sb.append("\"action\":\"").append(action).append("\",")
        sb.append("\"actionPointerId\":").append(actionPointerId).append(",")
        sb.append("\"timestamp\":").append(timestamp).append(",")
        sb.append("\"pointers\":[")
        for (i in pointers.indices) {
            val p = pointers[i]
            if (i > 0) sb.append(',')
            sb.append('{')
            sb.append("\"id\":").append(p.id).append(',')
            sb.append("\"toolType\":\"").append(p.toolType).append("\",")
            sb.append("\"x\":").append(fmt(p.x)).append(',')
            sb.append("\"y\":").append(fmt(p.y)).append(',')
            sb.append("\"pressure\":").append(fmt(p.pressure)).append(',')
            sb.append("\"tiltX\":").append(fmt(p.tiltX)).append(',')
            sb.append("\"tiltY\":").append(fmt(p.tiltY))
            if (p.button == null) sb.append(",\"button\":null")
            else sb.append(",\"button\":\"").append(p.button).append("\"")
            sb.append('}')
        }
        sb.append("]}")
        sb.append('\n')
        return sb.toString()
    }

    private fun fmt(v: Float): String {
        // Compact fixed precision; avoids locale decimal-comma issues.
        return String.format(java.util.Locale.US, "%.4f", v)
    }
}

/** Reads a big-endian Int64 from [b] at [offset]. */
fun readBE64(b: ByteArray, offset: Int): Long {
    var v = 0L
    for (i in 0 until 8) v = (v shl 8) or (b[offset + i].toLong() and 0xFF)
    return v
}

/**
 * Reads one [4-byte big-endian length][payload] frame from a stream.
 * Returns null at end-of-stream.
 */
fun readFrame(input: DataInputStream): ByteArray? {
    return try {
        val len = input.readInt() // readInt is big-endian
        if (len <= 0 || len > 64 * 1024 * 1024) return null
        val buf = ByteArray(len)
        input.readFully(buf)
        buf
    } catch (e: IOException) {
        null
    }
}
