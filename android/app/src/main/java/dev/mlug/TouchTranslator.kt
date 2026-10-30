package dev.mlug

import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import kotlin.math.hypot

/**
 * Maps tablet input to mouse semantics:
 *  - S Pen / stylus: hover moves the cursor, touch = left drag, side button or eraser = right button.
 *  - Mouse / trackpad (e.g. Bluetooth): passed through.
 *  - Finger: tap = click, drag = left drag, long-press = right click,
 *            two-finger drag = scroll, two-finger tap = right click.
 */
class TouchTranslator(private val view: View, private val client: () -> StreamClient?) {
    private enum class Mode { IDLE, PENDING, DRAG, SCROLL, DONE }

    private var mode = Mode.IDLE
    private var downX = 0f
    private var downY = 0f
    private var downTime = 0L
    private var lastCx = 0f
    private var lastCy = 0f
    private var scrollTravel = 0f
    private var stylusButton = -1
    private val slop = 12f * view.resources.displayMetrics.density
    private val handler = Handler(Looper.getMainLooper())
    private val longPress = Runnable {
        if (mode == Mode.PENDING) {
            click(Wire.RIGHT, downX, downY)
            mode = Mode.DONE
        }
    }

    private fun nx(x: Float) = (x / view.width).coerceIn(0f, 1f)
    private fun ny(y: Float) = (y / view.height).coerceIn(0f, 1f)
    private fun send(action: Int, button: Int, x: Float, y: Float) =
        client()?.pointer(action, button, nx(x), ny(y))

    private fun click(button: Int, x: Float, y: Float) {
        send(Wire.MOVE, button, x, y)
        send(Wire.DOWN, button, x, y)
        send(Wire.UP, button, x, y)
    }

    fun onGenericMotion(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_ENTER ->
                send(Wire.MOVE, Wire.LEFT, e.x, e.y)
            MotionEvent.ACTION_SCROLL -> {
                val px = 60f * view.resources.displayMetrics.density
                client()?.scroll(e.getAxisValue(MotionEvent.AXIS_HSCROLL) * -px, e.getAxisValue(MotionEvent.AXIS_VSCROLL) * px)
            }
            else -> return false
        }
        return true
    }

    fun onTouch(e: MotionEvent): Boolean {
        return when (e.getToolType(0)) {
            MotionEvent.TOOL_TYPE_STYLUS, MotionEvent.TOOL_TYPE_ERASER -> stylus(e)
            MotionEvent.TOOL_TYPE_MOUSE -> mouse(e)
            else -> finger(e)
        }
    }

    private fun stylus(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val right = e.getToolType(0) == MotionEvent.TOOL_TYPE_ERASER ||
                    e.buttonState and (MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_SECONDARY) != 0
                stylusButton = if (right) Wire.RIGHT else Wire.LEFT
                send(Wire.MOVE, stylusButton, e.x, e.y)
                send(Wire.DOWN, stylusButton, e.x, e.y)
            }
            MotionEvent.ACTION_MOVE -> send(Wire.MOVE, stylusButton, e.x, e.y)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                send(Wire.UP, stylusButton, e.x, e.y)
                stylusButton = -1
            }
        }
        return true
    }

    private fun mouse(e: MotionEvent): Boolean {
        val button = if (e.buttonState and MotionEvent.BUTTON_SECONDARY != 0) Wire.RIGHT else Wire.LEFT
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> send(Wire.DOWN, button, e.x, e.y).also { stylusButton = button }
            MotionEvent.ACTION_MOVE -> send(Wire.MOVE, stylusButton, e.x, e.y)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> send(Wire.UP, stylusButton, e.x, e.y)
        }
        return true
    }

    private fun centroid(e: MotionEvent): Pair<Float, Float> {
        var sx = 0f; var sy = 0f
        for (i in 0 until e.pointerCount) { sx += e.getX(i); sy += e.getY(i) }
        return sx / e.pointerCount to sy / e.pointerCount
    }

    private fun finger(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                mode = Mode.PENDING
                downX = e.x; downY = e.y; downTime = e.eventTime
                send(Wire.MOVE, Wire.LEFT, e.x, e.y)
                handler.postDelayed(longPress, 550)
            }
            MotionEvent.ACTION_POINTER_DOWN -> if (mode == Mode.PENDING) {
                handler.removeCallbacks(longPress)
                mode = Mode.SCROLL
                scrollTravel = 0f
                centroid(e).let { (x, y) -> lastCx = x; lastCy = y }
            }
            MotionEvent.ACTION_MOVE -> when (mode) {
                Mode.PENDING -> if (hypot(e.x - downX, e.y - downY) > slop) {
                    handler.removeCallbacks(longPress)
                    mode = Mode.DRAG
                    send(Wire.DOWN, Wire.LEFT, downX, downY)
                    send(Wire.MOVE, Wire.LEFT, e.x, e.y)
                }
                Mode.DRAG -> send(Wire.MOVE, Wire.LEFT, e.x, e.y)
                Mode.SCROLL -> {
                    val (cx, cy) = centroid(e)
                    val dx = cx - lastCx; val dy = cy - lastCy
                    lastCx = cx; lastCy = cy
                    scrollTravel += hypot(dx, dy)
                    if (dx != 0f || dy != 0f) client()?.scroll(dx, dy)
                }
                else -> {}
            }
            MotionEvent.ACTION_POINTER_UP -> if (mode == Mode.SCROLL && e.pointerCount == 2) {
                // Two-finger tap -> right click; a scroll just ends.
                if (scrollTravel < slop && e.eventTime - downTime < 350) click(Wire.RIGHT, downX, downY)
                mode = Mode.DONE
            }
            MotionEvent.ACTION_UP -> {
                handler.removeCallbacks(longPress)
                when (mode) {
                    Mode.PENDING -> click(Wire.LEFT, downX, downY)
                    Mode.DRAG -> send(Wire.UP, Wire.LEFT, e.x, e.y)
                    else -> {}
                }
                mode = Mode.IDLE
            }
            MotionEvent.ACTION_CANCEL -> {
                handler.removeCallbacks(longPress)
                if (mode == Mode.DRAG) send(Wire.UP, Wire.LEFT, e.x, e.y)
                mode = Mode.IDLE
            }
        }
        return true
    }
}
