package com.kimhwi.dailymapline

import com.kimhwi.dailymapline.core.Coordinate
import com.kimhwi.dailymapline.core.RoadRouting
import com.kimhwi.dailymapline.core.RouteResult
import com.kimhwi.dailymapline.core.decodePolyline6
import com.valhalla.valhalla.Valhalla
import org.json.JSONArray
import org.json.JSONObject

/** On-device routing over Valhalla tiles built from the OSM South Korea extract. Same rules as iOS. */
class ValhallaRouter(private val valhalla: Valhalla) : RoadRouting {
    override fun route(from: Coordinate, to: Coordinate, speedKmh: Double): RouteResult {
        if (!isCovered(from) || !isCovered(to)) return RouteResult.DataMissing
        // Travel mode is not classified; speed only decides which road network to try first.
        for (costing in if (speedKmh >= 25) listOf("auto", "pedestrian") else listOf("pedestrian", "auto")) {
            val path = request(from, to, costing).getOrNull() ?: continue
            if (path.size > 1) return RouteResult.Road(path)
        }
        return RouteResult.Failed
    }

    override fun hasNoRoad(near: Coordinate): Boolean {
        if (!isCovered(near)) return false
        // Both networks must miss: walkways are not drivable and motorways are not walkable.
        return listOf("pedestrian", "auto").all { request(near, near, it).exceptionOrNull()?.message?.contains("171") == true }
    }

    private fun request(from: Coordinate, to: Coordinate, costing: String): Result<List<Coordinate>> = runCatching {
        fun location(c: Coordinate) = JSONObject().put("lat", c.lat).put("lon", c.lon)
            .put("search_cutoff", SEARCH_CUTOFF).put("minimum_reachability", 0)
        val body = JSONObject().put("locations", JSONArray().put(location(from)).put(location(to)))
            .put("costing", costing).put("directions_type", "none")
        val legs = JSONObject(valhalla.routeRaw(body.toString())).getJSONObject("trip").getJSONArray("legs")
        (0 until legs.length()).flatMap { decodePolyline6(legs.getJSONObject(it).getString("shape")) }
    }

    private fun isCovered(point: Coordinate) = point.lon in 124.5..131.95 && point.lat in 33.0..38.65

    companion object {
        /** Same 80 m "a road is near" limit as iOS; Valhalla otherwise snaps up to 35 km away. */
        private const val SEARCH_CUTOFF = 80
    }
}
