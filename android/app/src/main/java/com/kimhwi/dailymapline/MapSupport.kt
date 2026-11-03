package com.kimhwi.dailymapline

import android.content.Context
import android.os.Bundle
import org.json.JSONArray
import org.json.JSONObject
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
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
            onReady(map)
        }
    }
}
