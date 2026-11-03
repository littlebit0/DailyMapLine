package com.kimhwi.dailymapline

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import com.kimhwi.dailymapline.core.Coordinate
import com.kimhwi.dailymapline.core.VideoTimeline
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.Style
import org.maplibre.android.snapshotter.MapSnapshot
import org.maplibre.android.snapshotter.MapSnapshotter
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.min

/** Renders frames from the output timeline, so generation time never changes playback length. */
object VideoRenderer {
    private const val WIDTH = 720
    private const val HEIGHT = 1280
    private const val FPS = 30
    private const val SCALE = 2f
    /** 57 dp on a 360 dp wide frame stands in for the 1.5 cm scale bar. Not a physical guarantee. */
    private const val SCALE_BAR_DP = 57.0

    suspend fun render(context: Context, label: String, timeline: VideoTimeline, progress: (Float) -> Unit): File {
        require(timeline.lengthMeters > 0) { "기록영상을 만들 수 있는 이동 경로가 없어요." }
        val style = MapStyle.json(context)
        val file = File(File(context.cacheDir, "videos").apply { mkdirs() }, "DailyMapLine-${label.replace(" – ", "_")}.mp4")
        file.delete()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, WIDTH, HEIGHT).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, 6_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        val muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var track = -1
        val info = MediaCodec.BufferInfo()
        fun drain(endOfStream: Boolean) {
            while (true) {
                val index = codec.dequeueOutputBuffer(info, if (endOfStream) 10_000 else 0)
                when {
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { track = muxer.addTrack(codec.outputFormat); muxer.start() }
                    index >= 0 -> {
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            muxer.writeSampleData(track, codec.getOutputBuffer(index)!!, info)
                        }
                        codec.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    }
                    else -> if (!endOfStream) return
                }
            }
        }
        try {
            val frames = maxOf(1, kotlin.math.ceil(timeline.durationSeconds * FPS).toInt())
            var scale = 1.0
            for (index in 0..frames) {
                val position = timeline.position(index.toDouble() / frames)
                val frame = timeline.frame(position) ?: continue
                scale += (frame.targetScaleKm - scale) * min(1.0, 7.0 / FPS)
                val snapshot = snapshot(context, style, frame.center, scale)
                val image = compose(snapshot, timeline.traces(position), label, scale)
                withContext(Dispatchers.Default) {
                    var input: Int
                    do { input = codec.dequeueInputBuffer(10_000); drain(false) } while (input < 0)
                    writeYuv(image, codec.getInputImage(input)!!)
                    codec.queueInputBuffer(input, 0, WIDTH * HEIGHT * 3 / 2, index * 1_000_000L / FPS, 0)
                    drain(false)
                }
                progress(index.toFloat() / frames)
            }
            withContext(Dispatchers.Default) {
                var input: Int
                do { input = codec.dequeueInputBuffer(10_000); drain(false) } while (input < 0)
                codec.queueInputBuffer(input, 0, 0, (frames + 1) * 1_000_000L / FPS, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                drain(true)
            }
        } finally {
            codec.stop(); codec.release()
            runCatching { muxer.stop() }
            muxer.release()
        }
        return file
    }

    private suspend fun snapshot(context: Context, style: String, center: Coordinate, scaleKm: Double): MapSnapshot =
        suspendCancellableCoroutine { continuation ->
            val metersPerDp = scaleKm * 1000 / SCALE_BAR_DP
            val zoom = ln(cos(Math.toRadians(center.lat)) * 40075016.686 / (512 * metersPerDp)) / ln(2.0)
            val options = MapSnapshotter.Options((WIDTH / SCALE).toInt(), (HEIGHT / SCALE).toInt())
                .withStyleBuilder(Style.Builder().fromJson(style))
                .withCameraPosition(CameraPosition.Builder().target(LatLng(center.lat, center.lon)).zoom(zoom).build())
                .withPixelRatio(SCALE)
                .withLogo(false)
            val snapshotter = MapSnapshotter(context, options)
            snapshotter.start({ continuation.resume(it) }, { continuation.resumeWithException(IllegalStateException("지도 화면을 그리지 못했어요. $it")) })
            continuation.invokeOnCancellation { snapshotter.cancel() }
        }

    private fun compose(snapshot: MapSnapshot, traces: List<List<Coordinate>>, label: String, scaleKm: Double): Bitmap {
        val bitmap = Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawBitmap(snapshot.bitmap, null, RectF(0f, 0f, WIDTH.toFloat(), HEIGHT.toFloat()), null)
        val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
        val ratio = WIDTH.toFloat() / snapshot.bitmap.width
        for ((color, width) in listOf(Color.WHITE to 4.5f, Color.rgb(36, 125, 221) to 2.5f)) {
            line.color = color
            line.strokeWidth = width * SCALE
            for (trace in traces) {
                val path = Path()
                trace.forEachIndexed { i, c ->
                    val p = snapshot.pixelForLatLng(LatLng(c.lat, c.lon))
                    if (i == 0) path.moveTo(p.x * ratio, p.y * ratio) else path.lineTo(p.x * ratio, p.y * ratio)
                }
                canvas.drawPath(path, line)
            }
        }
        drawLabel(canvas, label.replace("-", "."), 14f, 16f, 12f)
        val bar = Paint().apply { color = Color.rgb(40, 70, 91); strokeWidth = SCALE }
        canvas.drawLine(15 * SCALE, 584 * SCALE, (15 + SCALE_BAR_DP.toFloat()) * SCALE, 584 * SCALE, bar)
        drawLabel(canvas, String.format("%.1f km", scaleKm), 11f, 564f, 9f)
        drawLabel(canvas, "Protomaps · Map data © OpenStreetMap contributors · ODbL", 11f, 592f, 8f)
        return bitmap
    }

    private fun drawLabel(canvas: Canvas, text: String, x: Float, y: Float, size: Float) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(37, 62, 84); textSize = size * SCALE; isFakeBoldText = true }
        val top = y * SCALE
        val baseline = top - paint.ascent()
        val background = Paint().apply { color = Color.argb(230, 255, 255, 255) }
        canvas.drawRect(x * SCALE - 8, top - 4, x * SCALE + paint.measureText(text) + 8, baseline + paint.descent() + 4, background)
        canvas.drawText(text, x * SCALE, baseline, paint)
    }

    /** BT.601 conversion into whatever plane layout the encoder hands out. */
    private fun writeYuv(bitmap: Bitmap, image: android.media.Image) {
        val pixels = IntArray(WIDTH * HEIGHT)
        bitmap.getPixels(pixels, 0, WIDTH, 0, 0, WIDTH, HEIGHT)
        val (yPlane, uPlane, vPlane) = image.planes
        for (row in 0 until HEIGHT) for (col in 0 until WIDTH) {
            val c = pixels[row * WIDTH + col]
            val r = (c shr 16) and 0xFF; val g = (c shr 8) and 0xFF; val b = c and 0xFF
            yPlane.buffer.put(row * yPlane.rowStride + col * yPlane.pixelStride, (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).toByte())
            if (row % 2 == 0 && col % 2 == 0) {
                val u = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                val v = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                uPlane.buffer.put(row / 2 * uPlane.rowStride + col / 2 * uPlane.pixelStride, u.toByte())
                vPlane.buffer.put(row / 2 * vPlane.rowStride + col / 2 * vPlane.pixelStride, v.toByte())
            }
        }
    }
}
