package dev.mlug

import android.app.Activity
import android.graphics.Color
import android.graphics.Point
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.InputDevice
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView

class MainActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var surfaceView: SurfaceView
    private lateinit var status: TextView
    private var client: StreamClient? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        surfaceView = SurfaceView(this)
        status = TextView(this).apply {
            setTextColor(Color.GRAY)
            textSize = 18f
            gravity = Gravity.CENTER
        }
        setContentView(FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(surfaceView, FrameLayout.LayoutParams(-1, -1))
            addView(status, FrameLayout.LayoutParams(-1, -1))
        })

        val touch = TouchTranslator(surfaceView) { client }
        surfaceView.setOnTouchListener { _, e -> touch.onTouch(e) }
        surfaceView.setOnGenericMotionListener { _, e -> touch.onGenericMotion(e) }
        surfaceView.holder.addCallback(this)
        // Deliver touch/pen events as they arrive instead of batching them per vsync.
        if (Build.VERSION.SDK_INT >= 31) surfaceView.requestUnbufferedDispatch(InputDevice.SOURCE_CLASS_POINTER)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.apply {
                hide(WindowInsets.Type.systemBars())
                systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
        }
    }

    /** Full physical panel size in pixels, landscape. */
    private fun panelSize(): Point {
        val p = Point()
        if (Build.VERSION.SDK_INT >= 30) {
            val b = windowManager.maximumWindowMetrics.bounds
            p.set(b.width(), b.height())
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.getRealSize(p)
        }
        return Point(maxOf(p.x, p.y), minOf(p.x, p.y))
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        val size = panelSize()
        val dpi = resources.displayMetrics.xdpi.toInt()
        val decoder = intent.getStringExtra("decoder")
        client = StreamClient(holder.surface, size.x, size.y, dpi, decoder) { msg ->
            runOnUiThread {
                status.text = msg ?: ""
                status.visibility = if (msg == null) View.GONE else View.VISIBLE
            }
        }.also { it.start() }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        client?.stop()
        client = null
    }
}
