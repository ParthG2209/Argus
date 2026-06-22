package com.argus.client

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import androidx.appcompat.app.AppCompatActivity
import com.argus.client.databinding.ActivityMainBinding

/**
 * Full-screen host activity. Manages the decode pipeline, the network
 * connection, and the status overlay.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding

    private var decoder: VideoDecoder? = null
    private val audioPlayer = AudioPlayer()
    private val inputForwarder = InputForwarder()
    private var connection: ConnectionManager? = null

    @Volatile private var status = ConnectionManager.Status.DISCONNECTED
    @Volatile private var lastTool: InputMode? = null
    @Volatile private var lastPressure: Float = 0f
    private var fps = 0

    private val ui = Handler(Looper.getMainLooper())
    private var overlayVisible = true

    // Real panel resolution (landscape), detected at launch and reported to
    // the Mac so it sizes the virtual display to match (no black bars).
    private var screenW = 0
    private var screenH = 0
    private var screenRefresh = 144   // panel refresh (Hz), for clean-divisor pacing

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUi()

        detectScreenSize()
        selectHighRefreshMode()
        binding.surfaceView.setStreamAspect(screenW, screenH)
        binding.surfaceView.forwarder = inputForwarder
        binding.surfaceView.onInput = { tool, pressure ->
            lastTool = tool
            lastPressure = pressure
        }
        binding.surfaceView.onSurfaceReady = { surface -> onSurfaceReady(surface) }
        binding.surfaceView.onSurfaceDestroyed = { teardownPipeline() }

        // Tap the overlay to toggle its visibility.
        binding.statusOverlay.setOnClickListener {
            overlayVisible = !overlayVisible
            binding.statusOverlay.alpha = if (overlayVisible) 1f else 0.0f
        }

        startOverlayTicker()
    }

    private fun onSurfaceReady(surface: Surface) {
        if (decoder != null) return
        // Don't start the decoder yet — ConnectionManager starts it once the
        // codec handshake (H.264 / H.265) arrives on the video socket.
        val dec = VideoDecoder(surface, screenW, screenH)
        decoder = dec

        audioPlayer.start()

        val conn = ConnectionManager(dec, audioPlayer, inputForwarder, screenW, screenH, screenRefresh)
        conn.onStatus = { s -> status = s }
        conn.start()
        connection = conn
    }

    /** Detect the full panel resolution in landscape (w >= h). */
    private fun detectScreenSize() {
        var w: Int
        var h: Int
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            val bounds = windowManager.currentWindowMetrics.bounds
            w = bounds.width(); h = bounds.height()
        } else {
            val dm = android.util.DisplayMetrics()
            @Suppress("DEPRECATION") windowManager.defaultDisplay.getRealMetrics(dm)
            w = dm.widthPixels; h = dm.heightPixels
        }
        if (h > w) { val t = w; w = h; h = t }   // force landscape
        screenW = w; screenH = h
        android.util.Log.i("ArgusVideo", "Detected panel resolution ${screenW}x${screenH}")
    }

    /** Ask the system for the highest-refresh display mode (e.g. 144 Hz). */
    private fun selectHighRefreshMode() {
        val disp = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) display
                   else @Suppress("DEPRECATION") windowManager.defaultDisplay
        val modes = disp?.supportedModes ?: return
        // Prefer modes at the native resolution; pick the highest refresh.
        val atNative = modes.filter {
            (it.physicalWidth == screenW && it.physicalHeight == screenH) ||
            (it.physicalWidth == screenH && it.physicalHeight == screenW)
        }
        val best = (atNative.ifEmpty { modes.toList() }).maxByOrNull { it.refreshRate } ?: return
        val lp = window.attributes
        lp.preferredDisplayModeId = best.modeId
        window.attributes = lp
        screenRefresh = Math.round(best.refreshRate)
        android.util.Log.i("ArgusVideo",
            "Requested display mode ${best.physicalWidth}x${best.physicalHeight}@${best.refreshRate}Hz")
    }

    private fun teardownPipeline() {
        connection?.stop(); connection = null
        decoder?.stop(); decoder = null
        audioPlayer.stop()
    }

    // MARK: - Overlay

    private fun startOverlayTicker() {
        ui.post(object : Runnable {
            override fun run() {
                fps = decoder?.takeRenderedCount() ?: 0
                renderOverlay()
                ui.postDelayed(this, 1000)
            }
        })
    }

    private fun renderOverlay() {
        val statusText = when (status) {
            ConnectionManager.Status.DISCONNECTED -> "Disconnected"
            ConnectionManager.Status.CONNECTED -> "Connected"
            ConnectionManager.Status.STREAMING -> "Streaming"
        }
        val toolText = lastTool?.label ?: "—"
        val sb = StringBuilder()
        sb.append("ARGUS  ").append(statusText).append('\n')
        sb.append("FPS:  ").append(fps).append('\n')
        sb.append("Res:  2732×2048").append('\n')
        sb.append("Tool: ").append(toolText)
        if (lastTool == InputMode.STYLUS || lastTool == InputMode.ERASER) {
            sb.append('\n').append("Pres: ")
                .append(String.format(java.util.Locale.US, "%.2f", lastPressure))
        }
        binding.statusOverlay.text = sb.toString()
    }

    // MARK: - Immersive full-screen

    private fun hideSystemUi() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    override fun onDestroy() {
        super.onDestroy()
        ui.removeCallbacksAndMessages(null)
        teardownPipeline()
        inputForwarder.close()
    }
}
