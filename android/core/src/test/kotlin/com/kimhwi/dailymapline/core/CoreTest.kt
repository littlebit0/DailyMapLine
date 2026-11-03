package com.kimhwi.dailymapline.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class CoreTest {
    @Test fun speedBoundaries() {
        assertEquals(listOf(300L, 180L, 120L, 90L, 60L), listOf(6.99, 7.0, 25.0, 60.0, 80.0).map(::recordingIntervalSeconds))
    }

    @Test fun scaleBoundaries() {
        assertEquals(listOf(1.0, 1.5, 30.0, 30.0), listOf(1000.0, 1001.0, 20001.0, 99999.0).map(::scaleKm))
    }

    @Test fun stopsAfterFiveMinutesAndResumesOnSecondOutsideFix() {
        val policy = RecordingPolicy()
        val origin = Coordinate(127.0, 37.0)
        val far = Coordinate(127.01, 37.0)
        val results = listOf(
            policy.shouldRecord(origin, 0.0, 0),
            policy.shouldRecord(origin, 0.0, 300_000),
            policy.shouldRecord(far, 30.0, 400_000),
            policy.shouldRecord(far, 30.0, 410_000),
        )
        assertEquals(listOf(true, false, false, true), results)
    }

    @Test fun polyline6MatchesIos() {
        assertEquals(
            listOf(Coordinate(-120.2, 38.5), Coordinate(-120.95, 40.7), Coordinate(-126.453, 43.252)),
            decodePolyline6("_izlhA~rlgdF_{geC~ywl@_kwzCn`{nI"),
        )
    }

    @Test fun timelineLastsTwentySecondsAndSkipsGaps() {
        val a = Coordinate(127.0, 37.0)
        val b = Coordinate(127.02, 37.0)
        val c = Coordinate(127.04, 37.0)
        val length = distanceMeters(a, b)
        val timeline = VideoTimeline(listOf(
            Branch(1, 2, BranchState.Road, listOf(a, b)),
            Branch(2, 3, BranchState.Gap, emptyList()),
            Branch(3, 4, BranchState.Road, listOf(b, c)),
        ))
        assertEquals(length * 2, timeline.lengthMeters, 0.001)
        assertEquals(20.0, timeline.durationSeconds)
        assertEquals(0.0, VideoTimeline(emptyList()).durationSeconds)
        assertTrue(timeline.traces(0.0).isEmpty())
        assertEquals(1, timeline.traces(length * 2).size)
        assertTrue((timeline.frame(length / 2)?.targetScaleKm ?: 0.0) > 1)
    }

    @Test fun travelTimeEstimateMatchesIos() {
        assertEquals(listOf(300.0, 180.0, 120.0, 60.0), listOf(300.0, 900.0, 1500.0, 5000.0).map(::estimatedTravelSeconds))
    }

    @Test fun replayFollowsEstimatedTravelTime() {
        val start = Coordinate(127.0, 37.0)
        val walkEnd = Coordinate(127.003, 37.0)
        val driveEnd = Coordinate(127.103, 37.0)
        val timeline = VideoTimeline(listOf(
            Branch(1, 2, BranchState.Road, listOf(start, walkEnd)),
            Branch(2, 3, BranchState.Road, listOf(walkEnd, driveEnd)),
        ))
        val walkLength = distanceMeters(start, walkEnd)
        assertEquals(walkLength, timeline.position(300.0 / 360), 0.01)
        assertEquals(timeline.lengthMeters, timeline.position(1.0), 0.01)
        assertEquals(1.0, timeline.frame(walkLength / 2)!!.targetScaleKm)
        val driveScale = timeline.frame(walkLength + 4500)!!.targetScaleKm
        assertTrue(driveScale > 8 && driveScale <= 30)
    }
}
