package dev.mlug

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Connects to the Mac through the `adb reverse` tunnel, decodes the H.264 stream
 * straight onto [surface], and sends input back. Reconnects until [stop] is called.
 */
class StreamClient(
    private val surface: Surface,
    private val screenWidth: Int,
    private val screenHeight: Int,
    private val dpi: Int,
    private val decoderName: String?,
    private val onStatus: (String?) -> Unit,
) {
    @Volatile private var running = true
    @Volatile private var socket: Socket? = null
    @Volatile private var out: DataOutputStream? = null
    private val sender = Executors.newSingleThreadExecutor()
    private var codec: MediaCodec? = null
    private var outputThread: Thread? = null
    private var needKeyframe = true
    private val queuedAt = java.util.concurrent.ConcurrentHashMap<Long, Long>()
    private var statSum = 0L
    private var statN = 0

    private val thread = Thread({ loop() }, "mlug-stream")

    fun start() = thread.start()

    fun stop() {
        running = false
        try { socket?.close() } catch (_: IOException) {}
        thread.join(1000)
        sender.shutdownNow()
    }

    private fun loop() {
        while (running) {
            onStatus("Waiting for Mac…\nPlug in USB and start mlug on the Mac.")
            try {
                Socket().use { s ->
                    s.tcpNoDelay = true
                    s.receiveBufferSize = 4 shl 20
                    s.connect(InetSocketAddress("127.0.0.1", Wire.PORT), 1000)
                    socket = s
                    val input = DataInputStream(s.getInputStream().buffered(1 shl 16))
                    out = DataOutputStream(s.getOutputStream().buffered())
                    sendHello()
                    session(input)
                }
            } catch (e: IOException) {
                Log.d(TAG, "connection: ${e.message}")
            } finally {
                out = null
                socket = null
                releaseCodec()
            }
            if (running) Thread.sleep(700)
        }
    }

    private fun session(input: DataInputStream) {
        var buf = ByteArray(1 shl 20)
        while (running) {
            val type = input.readUnsignedByte()
            val len = input.readInt()
            if (len > buf.size) buf = ByteArray(len + (len shr 1))
            input.readFully(buf, 0, len)
            when (type) {
                Wire.CONFIG -> {
                    val bb = ByteBuffer.wrap(buf, 0, len)
                    configure(bb.int, bb.int)
                    onStatus(null)
                }
                Wire.FRAME -> {
                    val key = buf[0].toInt() and 1 != 0
                    val pts = ByteBuffer.wrap(buf, 1, 8).long
                    feed(buf, 9, len - 9, key, pts)
                }
            }
        }
    }

    // region decoder

    private fun configure(width: Int, height: Int) {
        releaseCodec()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            // Without these, decoders clock themselves for the default 30 fps budget.
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_OPERATING_RATE, 120)
            // Vendor hints; ignored where unsupported.
            setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            setInteger("vendor.low-latency.enable", 1)
            setInteger("vendor.mtk.ext.vdec.vpp.disabled.value", 1)
            setInteger("vendor.mtk.ext.vdec.vpp.motion.intpl.feature-on", 0)
            setInteger("vendor.mtk.vdec.cpu.boost.mode.value", 1)
        }
        val c = decoderName?.let { MediaCodec.createByCodecName(it) }
            ?: MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        c.configure(format, surface, null, 0)
        c.start()
        codec = c
        needKeyframe = true
        outputThread = Thread({ drain(c) }, "mlug-decode").also { it.start() }
        Log.i(TAG, "decoder ${c.name} ${width}x$height")
        if (Build.VERSION.SDK_INT >= 31) {
            Log.i(TAG, "vendor params: ${c.supportedVendorParameters}")
            val caps = c.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
            Log.i(TAG, "lowLatency feature: ${caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)}")
            Log.i(TAG, "input format: ${c.inputFormat}")
            Log.i(TAG, "output format: ${c.outputFormat}")
        }
    }

    private fun feed(data: ByteArray, off: Int, len: Int, key: Boolean, pts: Long) {
        val c = codec ?: return
        if (needKeyframe && !key) return
        needKeyframe = false
        try {
            val idx = c.dequeueInputBuffer(50_000)
            if (idx < 0) { requestKeyframe(); needKeyframe = true; return }
            c.getInputBuffer(idx)!!.apply { clear(); put(data, off, len) }
            queuedAt[pts] = System.nanoTime()
            c.queueInputBuffer(idx, 0, len, pts, 0)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "decoder error, requesting keyframe", e)
            needKeyframe = true
            requestKeyframe()
        }
    }

    private fun drain(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running && codec === c) {
                val idx = c.dequeueOutputBuffer(info, 100_000)
                if (idx >= 0) {
                    queuedAt.remove(info.presentationTimeUs)?.let { t ->
                        statSum += System.nanoTime() - t
                        if (++statN == 60) {
                            Log.i(TAG, "decode avg %.1fms, pending %d".format(statSum / 60 / 1e6, queuedAt.size))
                            statSum = 0; statN = 0
                        }
                    }
                    // Render immediately; frames are already paced by the Mac.
                    c.releaseOutputBuffer(idx, true)
                }
            }
        } catch (_: IllegalStateException) {
            // codec released
        }
    }

    private fun releaseCodec() {
        val c = codec ?: return
        codec = null
        outputThread?.join(500)
        outputThread = null
        try { c.stop() } catch (_: Exception) {}
        c.release()
    }

    // endregion

    // region outgoing

    private fun send(type: Int, write: DataOutputStream.() -> Unit) {
        if (sender.isShutdown) return
        sender.execute {
            val o = out ?: return@execute
            try {
                val body = java.io.ByteArrayOutputStream(16)
                DataOutputStream(body).write()
                o.writeByte(type)
                o.writeInt(body.size())
                body.writeTo(o)
                o.flush()
            } catch (_: IOException) {}
        }
    }

    private fun sendHello() = send(Wire.HELLO) {
        writeInt(Wire.VERSION); writeInt(screenWidth); writeInt(screenHeight); writeInt(dpi)
    }

    fun pointer(action: Int, button: Int, x: Float, y: Float) = send(Wire.POINTER) {
        writeByte(action); writeByte(button); writeFloat(x); writeFloat(y)
    }

    fun scroll(dx: Float, dy: Float) = send(Wire.SCROLL) { writeFloat(dx); writeFloat(dy) }

    fun requestKeyframe() = send(Wire.KEYFRAME) {}

    // endregion

    companion object { private const val TAG = "mlug" }
}
