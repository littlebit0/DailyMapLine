package com.kimhwi.dailymapline.core

/** Video playback over road branches only. Gaps and unconnected branches are skipped, never bridged. */
class VideoTimeline(branches: List<Branch>) {
    data class Frame(val center: Coordinate, val targetScaleKm: Double)

    private class Segment(val path: List<Coordinate>, val cumulative: List<Double>, val offset: Double, val length: Double)

    private val segments: List<Segment>
    val lengthMeters: Double

    init {
        var offset = 0.0
        val list = mutableListOf<Segment>()
        for (branch in branches) {
            if (branch.state != BranchState.Road) continue
            val cumulative = cumulativeDistances(branch.path)
            val length = cumulative.lastOrNull() ?: 0.0
            if (length <= 0) continue
            list += Segment(branch.path, cumulative, offset, length)
            offset += length
        }
        segments = list
        lengthMeters = offset
    }

    val durationSeconds get() = lengthMeters / 1000 * VIDEO_SECONDS_PER_KM

    fun position(fraction: Double) = lengthMeters * fraction

    fun frame(position: Double): Frame? {
        val segment = segments.firstOrNull { position <= it.offset + it.length } ?: segments.lastOrNull() ?: return null
        val local = (position - segment.offset).coerceIn(0.0, segment.length)
        val progress = local / segment.length
        val transition = minOf(1.0, progress / 0.15, (1 - progress) / 0.15).coerceAtLeast(0.0)
        val target = scaleKm(segment.length)
        return Frame(point(segment, local), 1 + (target - 1) * transition)
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
}
