package com.kimhwi.dailymapline.core

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

data class Coordinate(val lon: Double, val lat: Double)

/** Every record video lasts this long whatever the distance (user decision, replacing 1 s per km). */
const val VIDEO_DURATION_SECONDS = 20.0

fun distanceMeters(a: Coordinate, b: Coordinate): Double {
    val rad = Math.PI / 180
    val dLat = (b.lat - a.lat) * rad
    val dLon = (b.lon - a.lon) * rad
    val h = sin(dLat / 2).pow(2) + cos(a.lat * rad) * cos(b.lat * rad) * sin(dLon / 2).pow(2)
    return 6371008.8 * 2 * atan2(sqrt(h), sqrt(1 - h))
}

fun cumulativeDistances(path: List<Coordinate>): List<Double> {
    if (path.isEmpty()) return emptyList()
    val result = mutableListOf(0.0)
    for (i in 1 until path.size) result += result.last() + distanceMeters(path[i - 1], path[i])
    return result
}

fun scaleKm(branchLengthMeters: Double): Double =
    listOf(1.0, 1.5, 2.0, 3.0, 4.0, 5.0, 8.0, 12.0, 20.0, 30.0).firstOrNull { branchLengthMeters <= it * 1000 } ?: 30.0

fun recordingIntervalSeconds(speedKmh: Double): Long = when {
    speedKmh < 7 -> 300
    speedKmh < 25 -> 180
    speedKmh < 60 -> 120
    speedKmh < 80 -> 90
    else -> 60
}

/** Decodes Valhalla's encoded polyline with six digits of precision. */
fun decodePolyline6(encoded: String): List<Coordinate> {
    val result = mutableListOf<Coordinate>()
    var index = 0
    var lat = 0
    var lon = 0
    fun next(): Int? {
        var value = 0
        var shift = 0
        while (index < encoded.length) {
            val byte = encoded[index++].code - 63
            value = value or ((byte and 0x1F) shl shift)
            shift += 5
            if (byte < 0x20) return if (value and 1 != 0) (value shr 1).inv() else value shr 1
        }
        return null
    }
    while (index < encoded.length) {
        lat += next() ?: break
        lon += next() ?: break
        result += Coordinate(lon / 1e6, lat / 1e6)
    }
    return result
}
