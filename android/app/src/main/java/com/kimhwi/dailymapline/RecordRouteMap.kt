package com.kimhwi.dailymapline

import android.graphics.Color
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.kimhwi.dailymapline.core.Branch
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point

/** Route preview on the record video screen: branch lines only. */
@Composable
fun RecordRouteMap(branches: List<Branch>, modifier: Modifier = Modifier) {
    val paths = branches.map { it.path }.filter { it.size > 1 }
    AndroidView(
        modifier = modifier,
        factory = { context ->
            makeBaseMap(context) { map ->
                map.setStyle(Style.Builder().fromJson(MapStyle.json(context))) { style ->
                    style.addSource(GeoJsonSource("route"))
                    for ((id, color, width) in listOf(Triple("route-white", Color.WHITE, 7f), Triple("route-blue", Color.rgb(36, 125, 221), 3.5f))) {
                        style.addLayer(LineLayer(id, "route").withProperties(
                            PropertyFactory.lineColor(color), PropertyFactory.lineWidth(width),
                            PropertyFactory.lineCap(Property.LINE_CAP_ROUND), PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
                        ))
                    }
                }
            }
        },
        update = { view: MapView ->
            view.getMapAsync { map ->
                map.getStyle { style ->
                    style.getSourceAs<GeoJsonSource>("route")?.setGeoJson(FeatureCollection.fromFeatures(paths.map { path ->
                        Feature.fromGeometry(LineString.fromLngLats(path.map { Point.fromLngLat(it.lon, it.lat) }))
                    }))
                    val points = paths.flatten()
                    if (points.size > 1) {
                        val bounds = LatLngBounds.Builder().includes(points.map { LatLng(it.lat, it.lon) }).build()
                        map.moveCamera(CameraUpdateFactory.newLatLngBounds(bounds, 80))
                    }
                }
            }
        },
    )
}
