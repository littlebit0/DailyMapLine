package com.kimhwi.dailymapline

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.animation.ValueAnimator
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Bundle
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.animation.OvershootInterpolator
import android.widget.FrameLayout
import org.json.JSONArray
import org.json.JSONObject
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.MapLibreMap

object MapStyle {
    val center = LatLng(37.5682, 126.9795)

    /** Local style over the bundled Protomaps Korea extract, so the map makes no network requests. */
    fun json(context: Context): String {
        val app = context.applicationContext as DailyMapLineApp
        val layers = context.assets.open("basemap-layers.json").use { JSONArray(it.reader().readText()) }
        return JSONObject()
            .put("version", 8)
            .put("glyphs", "asset://Glyphs.bundle/{fontstack}/{range}.pbf")
            .put("sprite", "asset://light")
            .put("sources", JSONObject().put("protomaps", JSONObject()
                .put("type", "vector")
                .put("url", "pmtiles://file://" + app.dataFile("korea.pmtiles").absolutePath)
                .put("attribution", "Protomaps © OpenStreetMap")))
            .put("layers", layers)
            .toString()
    }
}

/** Shared setup for every interactive map. Screen-specific drawing lives with each screen's map. */
fun makeBaseMap(context: Context, onReady: (MapLibreMap) -> Unit): MapView {
    MapLibre.getInstance(context)
    return MapView(context).apply {
        onCreate(Bundle())
        getMapAsync { map ->
            map.uiSettings.isLogoEnabled = false
            map.uiSettings.isAttributionEnabled = false
            map.uiSettings.isCompassEnabled = false
            map.cameraPosition = CameraPosition.Builder().target(MapStyle.center).zoom(14.5).build()
            // Zoom moves to the left-edge strip, so double tap and double-tap-and-drag zoom are turned off.
            map.uiSettings.isDoubleTapGesturesEnabled = false
            map.uiSettings.isQuickZoomGesturesEnabled = false
            addView(ZoomStrip(context, map), FrameLayout.LayoutParams((44 * resources.displayMetrics.density).toInt(), FrameLayout.LayoutParams.MATCH_PARENT, Gravity.START))
            onReady(map)
        }
    }
}

/**
 * Vertical swipe along the left edge zooms: up zooms in, down zooms out. Pinch still works.
 * While dragging, the handle grows into a knob that follows the finger and shows the zoom direction.
 */
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
class ZoomStrip(context: Context, private val map: MapLibreMap) : View(context) {
    private val density = resources.displayMetrics.density
    private var startY = 0f
    private var startZoom = 0.0
    private var knobY = -1f
    private var progress = 0f
    private var sign = "+"
    private var animator: ValueAnimator? = null
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(36, 125, 221)
        textSize = 20 * density
        isFakeBoldText = true
        textAlign = Paint.Align.CENTER
    }

    init { contentDescription = "지도 확대 축소" }

    override fun onDraw(canvas: Canvas) {
        if (knobY < 0) knobY = height / 2f
        // Interpolates between the idle 4x64 bar and the 32x48 knob.
        val w = (4 + 28 * progress) * density
        val h = (64 - 16 * progress) * density
        val left = (6 - 2 * progress) * density
        val top = (knobY - h / 2).coerceIn(0f, height - h)
        fill.color = Color.argb((217 + 38 * progress).toInt(), 255, 255, 255)
        fill.setShadowLayer(4 * density * progress, 0f, density, Color.argb((64 * progress).toInt(), 0, 0, 0))
        canvas.drawRoundRect(RectF(left, top, left + w, top + h), w / 2, w / 2, fill)
        text.alpha = (255 * progress).toInt()
        canvas.drawText(sign, left + w / 2, top + h / 2 - (text.ascent() + text.descent()) / 2, text)
    }

    /** Springs between the bar and the knob; the system animation scale covers Reduce Motion. */
    private fun animateTo(target: Float, toY: Float?) {
        animator?.cancel()
        val fromProgress = progress
        val fromY = knobY
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 350
            interpolator = OvershootInterpolator(1.2f)
            addUpdateListener {
                val t = it.animatedValue as Float
                progress = fromProgress + (target - fromProgress) * t
                // While dragging only the size animates; the position always follows the finger.
                if (toY != null) knobY = fromY + (toY - fromY) * t
                invalidate()
            }
            start()
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                startY = event.y
                startZoom = map.cameraPosition.zoom
                knobY = event.y
                animateTo(1f, null)
            }
            MotionEvent.ACTION_MOVE -> {
                knobY = event.y
                sign = if (event.y <= startY) "+" else "−"
                invalidate()
                map.moveCamera(CameraUpdateFactory.zoomTo(startZoom - (event.y - startY) / (120 * density)))
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> animateTo(0f, height / 2f)
        }
        return true
    }

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD)
        info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD)
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean = when (action) {
        AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> { map.animateCamera(CameraUpdateFactory.zoomIn()); true }
        AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> { map.animateCamera(CameraUpdateFactory.zoomOut()); true }
        else -> super.performAccessibilityAction(action, arguments)
    }
}
