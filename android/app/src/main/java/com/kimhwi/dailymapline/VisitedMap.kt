package com.kimhwi.dailymapline

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
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
import kotlin.math.roundToInt

/**
 * Covers everything, then clears a 100 m wide stroke along each branch (50 m per side).
 * Stroking real paths keeps loop interiors covered unless buffers actually overlap there.
 */
@SuppressLint("ViewConstructor")
class FogOverlay(context: Context) : View(context) {
    var map: MapLibreMap? = null
    var paths: List<List<Coordinate>> = emptyList()
        set(value) { field = value; invalidate() }
    var location: Location? = null
        set(value) { field = value; invalidate() }

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

    override fun onDraw(canvas: Canvas) {
        val map = map ?: return
        val layer = canvas.saveLayer(null, null)
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), fog)
        for (path in paths) {
            if (path.size < 2) continue
            clear.strokeWidth = (100 / map.projection.getMetersPerPixelAtLatitude(path[0].lat)).toFloat()
            val line = android.graphics.Path()
            path.forEachIndexed { i, c ->
                val p = map.projection.toScreenLocation(LatLng(c.lat, c.lon))
                if (i == 0) line.moveTo(p.x, p.y) else line.lineTo(p.x, p.y)
            }
            canvas.drawPath(line, clear)
        }
        canvas.restoreToCount(layer)
        drawLocation(canvas, map)
    }

    /** Drawn here because the map's own marker would sit under the fog and be dimmed. */
    private fun drawLocation(canvas: Canvas, map: MapLibreMap) {
        val location = location ?: return
        val p = map.projection.toScreenLocation(LatLng(location.latitude, location.longitude))
        val density = resources.displayMetrics.density
        if (location.hasBearing()) {
            // Compass degrees run clockwise from north; canvas angles run clockwise from east.
            val center = location.bearing - map.cameraPosition.bearing.toFloat() - 90
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

/** The map screen: reveals visited areas and shows the current position. It never draws route lines. */
@Composable
fun VisitedMap(branches: List<Branch>, location: Location?, recenterRequest: Int, modifier: Modifier = Modifier) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            val overlay = FogOverlay(context)
            val mapView = makeBaseMap(context) { map ->
                map.setStyle(Style.Builder().fromJson(MapStyle.json(context)))
                overlay.map = map
                map.addOnCameraMoveListener { overlay.invalidate() }
                map.addOnCameraIdleListener { overlay.invalidate() }
            }
            FrameLayout(context).apply {
                addView(mapView)
                addView(overlay)
                tag = Holder(overlay, 0)
            }
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

