package com.kimhwi.dailymapline

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.view.View
import android.widget.FrameLayout
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.kimhwi.dailymapline.core.Branch
import com.kimhwi.dailymapline.core.Coordinate
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.Style
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.math.tan

/**
 * Covers everything, then clears a 100 m wide stroke along each branch (50 m per side).
 * Stroking real paths keeps loop interiors covered unless buffers actually overlap there.
 */
@SuppressLint("ViewConstructor")
class FogOverlay(context: Context) : View(context) {
    var map: MapLibreMap? = null
    var paths: List<List<Coordinate>> = emptyList()
        set(value) {
            field = value
            // Projected once; each frame only applies one matrix instead of asking the map per point.
            origin = value.firstOrNull()?.firstOrNull()?.let(::mercator) ?: (0.0 to 0.0)
            mercatorPaths = value.filter { it.size > 1 }.map { path ->
                val line = android.graphics.Path()
                path.forEachIndexed { i, c ->
                    val (x, y) = local(mercator(c))
                    if (i == 0) line.moveTo(x, y) else line.lineTo(x, y)
                }
                line to (100 / (40075016.686 * cos(Math.toRadians(path[0].lat))) * LOCAL_SCALE).toFloat()
            }
            invalidate()
        }
    private var origin = 0.0 to 0.0
    private var mercatorPaths: List<Pair<android.graphics.Path, Float>> = emptyList()
    private val screenPath = android.graphics.Path()
    private val matrix = Matrix()
    var location: Location? = null
        set(value) {
            // Direction of travel from the last fix, for when no compass reading is available.
            val previous = field
            if (previous != null && value != null && previous.distanceTo(value) >= 5) course = previous.bearingTo(value)
            field = value
            invalidate()
        }
    private var course: Float? = null
    /** Compass heading toward true north, or null when the sensor is missing or unreliable. */
    private var heading: Float? = null
    private val sensors = context.getSystemService(SensorManager::class.java)
    private val rotation = FloatArray(9)
    private val orientation = FloatArray(3)
    private val compass = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            if (event.accuracy == SensorManager.SENSOR_STATUS_UNRELIABLE) { heading = null; return }
            SensorManager.getRotationMatrixFromVector(rotation, event.values)
            SensorManager.getOrientation(rotation, orientation)
            val magnetic = Math.toDegrees(orientation[0].toDouble()).toFloat()
            val declination = location?.let { GeomagneticField(it.latitude.toFloat(), it.longitude.toFloat(), it.altitude.toFloat(), it.time).declination } ?: 0f
            heading = (magnetic + declination + 360) % 360
            invalidate()
        }

        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) = Unit
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        sensors?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)?.let { sensors.registerListener(compass, it, SensorManager.SENSOR_DELAY_UI) }
    }

    override fun onDetachedFromWindow() {
        sensors?.unregisterListener(compass)
        super.onDetachedFromWindow()
    }

    private val fog = Paint().apply { color = Color.argb(171, 113, 134, 150) }
    private val clear = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(37, 62, 84)
        textSize = 13 * resources.displayMetrics.scaledDensity
        isFakeBoldText = true
        textAlign = Paint.Align.CENTER
    }
    private val blue = Color.rgb(36, 125, 221)

    private fun local(m: Pair<Double, Double>) =
        ((m.first - origin.first) * LOCAL_SCALE).toFloat() to ((m.second - origin.second) * LOCAL_SCALE).toFloat()

    override fun onDraw(canvas: Canvas) {
        val map = map ?: return
        val layer = canvas.saveLayer(null, null)
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), fog)
        val (ax, ay) = local(mercator(map.projection.fromScreenLocation(PointF(0f, 0f)).let { Coordinate(it.longitude, it.latitude) }))
        val (bx, by) = local(mercator(map.projection.fromScreenLocation(PointF(width.toFloat(), 0f)).let { Coordinate(it.longitude, it.latitude) }))
        val scale = width / hypot(bx - ax, by - ay)
        matrix.setTranslate(-ax, -ay)
        matrix.postScale(scale, scale)
        matrix.postRotate(-Math.toDegrees(atan2((by - ay).toDouble(), (bx - ax).toDouble())).toFloat())
        for ((line, widthUnits) in mercatorPaths) {
            line.transform(matrix, screenPath)
            clear.strokeWidth = widthUnits * scale
            canvas.drawPath(screenPath, clear)
        }
        canvas.restoreToCount(layer)
        drawLocation(canvas, map)
    }

    /** Drawn here because the map's own marker would sit under the fog and be dimmed. */
    private fun drawLocation(canvas: Canvas, map: MapLibreMap) {
        val location = location ?: return
        val p = map.projection.toScreenLocation(LatLng(location.latitude, location.longitude))
        val density = resources.displayMetrics.density
        // Compass first, like iOS; the emulator and some phones report a bearing of 0 that is not real.
        val direction = heading ?: course
        if (direction != null) {
            // Compass degrees run clockwise from north; canvas angles run clockwise from east.
            val center = direction - map.cameraPosition.bearing.toFloat() - 90
            val radius = 36 * density
            fill.color = Color.argb(89, 36, 125, 221)
            canvas.drawArc(RectF(p.x - radius, p.y - radius, p.x + radius, p.y + radius), center - 36, 72f, true, fill)
        }
        fill.color = Color.WHITE
        canvas.drawCircle(p.x, p.y, 10 * density, fill)
        fill.color = blue
        canvas.drawCircle(p.x, p.y, 7 * density, fill)
        // A missing speed means no valid reading, which is not the same as standing still.
        val label = if (location.hasSpeed()) "${(location.speed * 3.6).roundToInt()} km/h" else "-- km/h"
        contentDescription = "현재 속도 $label"
        val y = p.y + 14 * density - text.ascent()
        val half = text.measureText(label) / 2 + 6 * density
        fill.color = Color.argb(235, 255, 255, 255)
        canvas.drawRoundRect(RectF(p.x - half, y + text.ascent() - 2 * density, p.x + half, y + text.descent() + 2 * density), 6 * density, 6 * density, fill)
        canvas.drawText(label, p.x, y, text)
    }
}

/** Web Mercator in world units (0..1), the projection the map draws in, so screen = similarity transform. */
private fun mercator(c: Coordinate): Pair<Double, Double> {
    val lat = Math.toRadians(c.lat)
    return (c.lon + 180) / 360 to (1 - ln(tan(lat) + 1 / cos(lat)) / Math.PI) / 2
}

/** Floats lose metres at world scale, so paths are stored relative to an origin and magnified. */
private const val LOCAL_SCALE = 16_777_216.0

/** The map screen: reveals visited areas and shows the current position. It never draws route lines. */
@Composable
fun VisitedMap(branches: List<Branch>, location: Location?, recenterRequest: Int, modifier: Modifier = Modifier) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            val overlay = FogOverlay(context)
            val container = FrameLayout(context)
            val mapView = makeBaseMap(context) { map ->
                map.setStyle(Style.Builder().fromJson(MapStyle.json(context)))
                overlay.map = map
                map.addOnCameraMoveListener { overlay.invalidate() }
                map.addOnCameraIdleListener { overlay.invalidate() }
            }
            container.apply {
                addView(mapView)
                addView(overlay)
                tag = Holder(overlay, 0)
            }
            // The zoom strip moves above the fog so its handle is not dimmed.
            mapView.getMapAsync {
                val strip = (0 until mapView.childCount).map(mapView::getChildAt).firstOrNull { it is ZoomStrip } ?: return@getMapAsync
                val params = strip.layoutParams
                mapView.removeView(strip)
                container.addView(strip, params)
            }
            container
        },
        update = { view ->
            val holder = view.tag as Holder
            holder.overlay.paths = branches.map { it.path }.filter { it.size > 1 }
            holder.overlay.location = location
            if (recenterRequest != holder.handledRecenter && location != null) {
                holder.handledRecenter = recenterRequest
                holder.overlay.map?.animateCamera(CameraUpdateFactory.newLatLng(LatLng(location.latitude, location.longitude)))
            }
        },
    )
}

private class Holder(val overlay: FogOverlay, var handledRecenter: Int)

