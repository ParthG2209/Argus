package com.argus.client

import android.content.Context
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView

/**
 * Full-screen SurfaceView that:
 *   - preserves the stream's aspect ratio (letterboxed by the black parent)
 *   - hints a 60 Hz fixed source frame rate
 *   - captures finger + stylus input (including hover and batched history)
 *     and forwards it via [InputForwarder]
 */
class StreamSurfaceView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null, defStyle: Int = 0
) : SurfaceView(context, attrs, defStyle), SurfaceHolder.Callback {

    var forwarder: InputForwarder? = null
    /** Reports the active tool + live pressure to the overlay. */
    var onInput: ((tool: InputMode, pressure: Float) -> Unit)? = null
    /** Fired when the rendering Surface is ready. */
    var onSurfaceReady: ((Surface) -> Unit)? = null
    var onSurfaceDestroyed: (() -> Unit)? = null

    private val streamAspect = 2732f / 2048f

    init {
        holder.addCallback(this)
        isFocusable = true
        isFocusableInTouchMode = true
    }

    // MARK: - Aspect-ratio letterboxing

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = MeasureSpec.getSize(heightMeasureSpec)
        if (w == 0 || h == 0) { setMeasuredDimension(w, h); return }
        val viewAspect = w.toFloat() / h.toFloat()
        val (mw, mh) = if (viewAspect > streamAspect) {
            (h * streamAspect).toInt() to h   // pillarbox
        } else {
            w to (w / streamAspect).toInt()   // letterbox
        }
        setMeasuredDimension(mw, mh)
    }

    // MARK: - Surface lifecycle

    override fun surfaceCreated(holder: SurfaceHolder) {
        runCatching {
            holder.surface.setFrameRate(60f, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
        }
        onSurfaceReady?.invoke(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        onSurfaceDestroyed?.invoke()
    }

    // MARK: - Input

    override fun onTouchEvent(event: MotionEvent): Boolean {
        return handleMotion(event) || super.onTouchEvent(event)
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        // Required for ACTION_HOVER_MOVE — does NOT arrive via onTouchEvent.
        return handleMotion(event) || super.onGenericMotionEvent(event)
    }

    private fun handleMotion(event: MotionEvent): Boolean {
        val action = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> "down"
            MotionEvent.ACTION_MOVE -> "move"
            MotionEvent.ACTION_UP -> "up"
            MotionEvent.ACTION_HOVER_MOVE -> "hover"
            MotionEvent.ACTION_BUTTON_PRESS -> "button_press"
            MotionEvent.ACTION_BUTTON_RELEASE -> "button_release"
            else -> return false
        }

        val toolType = when (event.getToolType(0)) {
            MotionEvent.TOOL_TYPE_STYLUS -> "stylus"
            MotionEvent.TOOL_TYPE_ERASER -> "eraser"
            else -> "finger"
        }

        val button = when {
            event.isButtonPressed(MotionEvent.BUTTON_STYLUS_PRIMARY) -> "primary"
            event.isButtonPressed(MotionEvent.BUTTON_STYLUS_SECONDARY) -> "secondary"
            else -> null
        }

        val w = width.toFloat().coerceAtLeast(1f)
        val h = height.toFloat().coerceAtLeast(1f)
        val points = ArrayList<InputPoint>(event.historySize + 1)

        // Flush historical (batched) intermediate samples first, oldest first.
        for (i in 0 until event.historySize) {
            points.add(
                InputPoint(
                    x = event.getHistoricalX(i) / w,
                    y = event.getHistoricalY(i) / h,
                    pressure = event.getHistoricalPressure(i),
                    tiltX = event.getHistoricalAxisValue(MotionEvent.AXIS_TILT, i),
                    tiltY = event.getHistoricalAxisValue(MotionEvent.AXIS_ORIENTATION, i),
                    toolMajor = event.getHistoricalAxisValue(MotionEvent.AXIS_TOOL_MAJOR, i),
                    toolMinor = event.getHistoricalAxisValue(MotionEvent.AXIS_TOOL_MINOR, i),
                    timestamp = event.getHistoricalEventTime(i),
                )
            )
        }
        // Then the current sample.
        points.add(
            InputPoint(
                x = event.x / w,
                y = event.y / h,
                pressure = event.pressure,
                tiltX = event.getAxisValue(MotionEvent.AXIS_TILT),
                tiltY = event.getAxisValue(MotionEvent.AXIS_ORIENTATION),
                toolMajor = event.getAxisValue(MotionEvent.AXIS_TOOL_MAJOR),
                toolMinor = event.getAxisValue(MotionEvent.AXIS_TOOL_MINOR),
                timestamp = event.eventTime,
            )
        )

        forwarder?.send(InputBatch(action, toolType, button, points))

        val mode = when {
            action == "hover" -> InputMode.HOVER
            toolType == "stylus" -> InputMode.STYLUS
            toolType == "eraser" -> InputMode.ERASER
            else -> InputMode.FINGER
        }
        onInput?.invoke(mode, event.pressure)
        return true
    }
}

enum class InputMode(val label: String) {
    FINGER("Finger"), STYLUS("Stylus"), ERASER("Eraser"), HOVER("Hover")
}
