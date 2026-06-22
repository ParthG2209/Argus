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

/** One sampled input point in normalized device space. */
data class InputPoint(
    val x: Float,
    val y: Float,
    val pressure: Float,
    val tiltX: Float,
    val tiltY: Float,
    val toolMajor: Float,
    val toolMinor: Float,
    val timestamp: Long,
)

/** A batch of points belonging to one MotionEvent dispatch. */
data class InputBatch(
    val action: String,
    val toolType: String,
    val button: String?,
    val points: List<InputPoint>,
) {
    /** Serialize to the newline-terminated JSON wire form, by hand for speed. */
    fun toJsonLine(): String {
        val sb = StringBuilder(64 + points.size * 96)
        sb.append('{')
        sb.append("\"action\":\"").append(action).append("\",")
        sb.append("\"toolType\":\"").append(toolType).append("\",")
        if (button == null) sb.append("\"button\":null,")
        else sb.append("\"button\":\"").append(button).append("\",")
        sb.append("\"points\":[")
        for (i in points.indices) {
            val p = points[i]
            if (i > 0) sb.append(',')
            sb.append('{')
            sb.append("\"x\":").append(fmt(p.x)).append(',')
            sb.append("\"y\":").append(fmt(p.y)).append(',')
            sb.append("\"pressure\":").append(fmt(p.pressure)).append(',')
            sb.append("\"tiltX\":").append(fmt(p.tiltX)).append(',')
            sb.append("\"tiltY\":").append(fmt(p.tiltY)).append(',')
            sb.append("\"toolMajor\":").append(fmt(p.toolMajor)).append(',')
            sb.append("\"toolMinor\":").append(fmt(p.toolMinor)).append(',')
            sb.append("\"timestamp\":").append(p.timestamp)
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
