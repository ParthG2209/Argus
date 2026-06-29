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

    // Stream aspect ratio; set from the detected panel resolution so the
    // SurfaceView fills the screen exactly (no letterboxing when they match).
    private var streamAspect = 2732f / 2048f

    /** Set the stream aspect from the tablet's real pixel resolution. */
    fun setStreamAspect(width: Int, height: Int) {
        if (width > 0 && height > 0) {
            streamAspect = width.toFloat() / height.toFloat()
            requestLayout()
        }
    }

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
        // Hint the panel to run at its highest refresh so high-fps streams
        // display smoothly (the source rate is variable, so SEAMLESS is fine).
        val maxRate = display?.supportedModes?.maxOfOrNull { it.refreshRate }
            ?: display?.refreshRate ?: 60f
        runCatching {
            holder.surface.setFrameRate(maxRate, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
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
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> "down"
            MotionEvent.ACTION_MOVE -> "move"
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> "up"
            MotionEvent.ACTION_CANCEL -> "cancel"
            MotionEvent.ACTION_HOVER_MOVE -> "hover"
            MotionEvent.ACTION_BUTTON_PRESS -> "button_press"
            MotionEvent.ACTION_BUTTON_RELEASE -> "button_release"
            else -> return false
        }

        // The pointer that triggered this action (meaningful for down/up)
        val actionPointerId = event.getPointerId(event.actionIndex)

        val w = width.toFloat().coerceAtLeast(1f)
        val h = height.toFloat().coerceAtLeast(1f)

        // 1. Flush historical (batched) intermediate samples first.
        // History is only present for ACTION_MOVE and ACTION_HOVER_MOVE.
        // NOTE: We intentionally skip sending historical events for touch navigation. 
        // Sending 300+ injected CGEvents per second floods the macOS WindowServer 
        // and causes severe stuttering/lag during window drags. 
        // The display refresh rate (e.g. 120Hz) provides enough samples for smooth movement.

        // 2. Process current sample.
        val ptrs = ArrayList<InputPointer>(event.pointerCount)
        for (pIdx in 0 until event.pointerCount) {
            ptrs.add(
                InputPointer(
                    id = event.getPointerId(pIdx),
                    toolType = getToolType(event, pIdx),
                    x = event.getX(pIdx) / w,
                    y = event.getY(pIdx) / h,
                    pressure = event.getPressure(pIdx),
                    tiltX = event.getAxisValue(MotionEvent.AXIS_TILT, pIdx),
                    tiltY = event.getAxisValue(MotionEvent.AXIS_ORIENTATION, pIdx),
                    button = getButton(event)
                )
            )
        }
        forwarder?.send(InputFrame(action, actionPointerId, event.eventTime, ptrs))

        // UI reporting (just take the first pointer to show what's active)
        val firstTool = getToolType(event, 0)
        val mode = when {
            action == "hover" -> InputMode.HOVER
            firstTool == "stylus" -> InputMode.STYLUS
            firstTool == "eraser" -> InputMode.ERASER
            else -> InputMode.FINGER
        }
        onInput?.invoke(mode, event.pressure)
        return true
    }
    
    private fun getToolType(event: MotionEvent, pIdx: Int): String {
        return when (event.getToolType(pIdx)) {
            MotionEvent.TOOL_TYPE_STYLUS -> "stylus"
            MotionEvent.TOOL_TYPE_ERASER -> "eraser"
            else -> "finger"
        }
    }
    
    private fun getButton(event: MotionEvent): String? {
        return when {
            event.isButtonPressed(MotionEvent.BUTTON_STYLUS_PRIMARY) -> "primary"
            event.isButtonPressed(MotionEvent.BUTTON_STYLUS_SECONDARY) -> "secondary"
            else -> null
        }
    }
}

enum class InputMode(val label: String) {
    FINGER("Finger"), STYLUS("Stylus"), ERASER("Eraser"), HOVER("Hover")
}

