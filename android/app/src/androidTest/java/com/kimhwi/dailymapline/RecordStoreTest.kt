package com.kimhwi.dailymapline

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.kimhwi.dailymapline.core.BranchState
import com.kimhwi.dailymapline.core.Coordinate
import com.kimhwi.dailymapline.core.RoadRouting
import com.kimhwi.dailymapline.core.RouteResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RecordStoreTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private fun store() = RecordStore(context, null)
    private val straight = object : RoadRouting {
        override fun route(from: Coordinate, to: Coordinate, speedKmh: Double) = RouteResult.Road(listOf(from, to))
        override fun hasNoRoad(near: Coordinate) = false
    }
    private val a = Coordinate(126.9774, 37.5664)
    private val b = Coordinate(126.9770, 37.5701)
    private val c = Coordinate(126.9831, 37.5703)

    @Test fun nextDayStartsFromPreviousLastNode() {
        val store = store()
        val first = store.record(a, "2026-10-31", straight)
        val second = store.record(b, "2026-11-01", straight)
        val branch = store.branches("2026-11-01").single()
        assertEquals(first.id to second.id, branch.from to branch.to)
        assertEquals(listOf("2026-10-31", "2026-11-01"), store.recordedDates())
    }

    @Test fun deletingDayKeepsBoundaryNode() {
        val store = store()
        store.record(a, "2026-10-31", straight)
        store.record(b, "2026-10-31", straight)
        store.record(c, "2026-11-01", straight)
        val kept = store.branches("2026-11-01")
        assertEquals(1, kept.size)
        assertEquals(DeletionPreview(1, 1, 1, listOf("2026-11-01")), store.deletionPreview("2026-10-31"))
        store.deleteDay("2026-10-31")
        assertEquals(listOf("2026-11-01"), store.recordedDates())
        assertEquals(kept, store.branches("2026-11-01"))
        store.deleteDay("2026-11-01")
        assertEquals(null, store.lastNode())
    }

    @Test fun gapAndMissingDataStayUnconnected() {
        val store = store()
        store.record(a, "2026-10-31", null)
        store.record(b, "2026-10-31", null)
        store.record(c, "2026-10-31", straight, afterGap = true)
        assertEquals(listOf(BranchState.DataMissing, BranchState.Gap), store.branches("2026-10-31").map { it.state })
        assertEquals(1, store.recalculateUnconnected(straight))
        assertEquals(listOf(BranchState.Road, BranchState.Gap), store.branches("2026-10-31").map { it.state })
    }

    @Test fun backupRoundTripAndDamageRejected() {
        val source = store()
        source.record(a, "2026-10-31", straight)
        source.record(b, "2026-11-01", straight)
        val backup = source.exportBackup()
        val target = store()
        target.record(c, "2026-12-25", null)
        target.restoreBackup(backup)
        assertEquals(source.recordedDates(), target.recordedDates())
        assertEquals(source.branches("2026-11-01"), target.branches("2026-11-01"))
        backup[backup.size - 1] = (backup.last().toInt() xor 0xFF).toByte()
        assertThrows(StoreException::class.java) { target.restoreBackup(backup) }
        assertEquals(source.recordedDates(), target.recordedDates())
    }
}
