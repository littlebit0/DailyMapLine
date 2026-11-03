package com.kimhwi.dailymapline.core

/**
 * Real travel time a branch most likely took, from its length alone (no timestamps are stored).
 * Nodes are recorded at speed-dependent intervals, so the interval consistent with
 * length / interval is the best estimate: under 583 m 300 s, under 1,250 m 180 s,
 * under 2,000 m 120 s, otherwise 60 s.
 */
fun estimatedTravelSeconds(lengthMeters: Double): Double =
    listOf(300L, 180L, 120L, 90L, 60L).firstOrNull { recordingIntervalSeconds(lengthMeters / it * 3.6) == it }?.toDouble() ?: 60.0

/**
 * Video playback over road branches only. Gaps and unconnected branches are skipped, never bridged.
 * The fixed video length is shared by estimated real travel time, so the replay keeps the rhythm of
 * the day: walking moves slowly on screen, driving quickly. The camera zooms out with on-screen speed.
 */
class VideoTimeline(branches: List<Branch>) {
    data class Frame(val center: Coordinate, val targetScaleKm: Double)

    private class Segment(
        val path: List<Coordinate>, val cumulative: List<Double>,
        val offset: Double, val length: Double, val timeOffset: Double, val time: Double,
    )

    private val segments: List<Segment>
    val lengthMeters: Double
    private val totalTime: Double

    init {
        var offset = 0.0
        var time = 0.0
        val list = mutableListOf<Segment>()
        for (branch in branches) {
            if (branch.state != BranchState.Road) continue
            val cumulative = cumulativeDistances(branch.path)
            val length = cumulative.lastOrNull() ?: 0.0
            if (length <= 0) continue
            val seconds = estimatedTravelSeconds(length)
            list += Segment(branch.path, cumulative, offset, length, time, seconds)
            offset += length
            time += seconds
        }
        segments = list
        lengthMeters = offset
        totalTime = time
    }

    val durationSeconds get() = if (lengthMeters > 0) VIDEO_DURATION_SECONDS else 0.0

    /** Position in meters for a playback fraction 0..1, following estimated travel time. */
    fun position(fraction: Double): Double {
        val time = fraction.coerceIn(0.0, 1.0) * totalTime
        val segment = segments.firstOrNull { time <= it.timeOffset + it.time } ?: segments.lastOrNull() ?: return 0.0
        return segment.offset + segment.length * ((time - segment.timeOffset) / segment.time).coerceIn(0.0, 1.0)
    }

    fun frame(position: Double): Frame? {
        val segment = segments.firstOrNull { position <= it.offset + it.length } ?: segments.lastOrNull() ?: return null
        val local = (position - segment.offset).coerceIn(0.0, segment.length)
        val progress = local / segment.length
        val transition = minOf(1.0, progress / 0.15, (1 - progress) / 0.15).coerceAtLeast(0.0)
        val byLength = 1 + (scaleKm(segment.length) - 1) * transition
        val metersPerVideoSecond = segment.length / (segment.time / totalTime * VIDEO_DURATION_SECONDS)
        val bySpeed = metersPerVideoSecond / MAX_FRAME_WIDTHS_PER_SECOND / METERS_PER_FRAME_WIDTH_PER_KM
        return Frame(point(segment, local), minOf(30.0, maxOf(byLength, bySpeed)))
    }

    /** Lines drawn so far. */
    fun traces(upTo: Double): List<List<Coordinate>> {
        val traces = mutableListOf<MutableList<Coordinate>>()
        for (segment in segments) {
            if (segment.offset > upTo) continue
            val to = minOf(segment.length, upTo - segment.offset)
            if (to <= 0) continue
            val slice = mutableListOf(segment.path[0])
            segment.cumulative.forEachIndexed { i, d -> if (d > 0 && d < to) slice += segment.path[i] }
            slice += point(segment, to)
            if (traces.isNotEmpty() && traces.last().last() == slice.first()) traces.last() += slice.drop(1) else traces += slice
        }
        return traces
    }

    private fun point(segment: Segment, distance: Double): Coordinate {
        var i = 1
        while (i < segment.cumulative.size - 1 && segment.cumulative[i] < distance) i++
        val span = segment.cumulative[i] - segment.cumulative[i - 1]
        val ratio = if (span > 0) (distance - segment.cumulative[i - 1]) / span else 0.0
        val a = segment.path[i - 1]
        val b = segment.path[i]
        return Coordinate(a.lon + (b.lon - a.lon) * ratio, a.lat + (b.lat - a.lat) * ratio)
    }

    private companion object {
        /** Map width the 360 dp frame shows per km of scale bar (57 dp per bar). */
        const val METERS_PER_FRAME_WIDTH_PER_KM = 1000.0 / 57 * 360
        /** Keeps the moving point from crossing more than a third of the frame per second. */
        const val MAX_FRAME_WIDTHS_PER_SECOND = 1 / 3.0
    }
}
