package com.kimhwi.dailymapline.core

/**
 * Decides which location fixes become nodes. Times here are transient and never persisted per node.
 * Experimental rule: within 100 m of an anchor for 5 minutes means stopped; 2 consecutive fixes outside resume.
 */
class RecordingPolicy {
    var isStopped = false
        private set
    private var anchor: Coordinate? = null
    private var anchorTime = 0L
    private var outsideCount = 0
    private var lastNodeTime = 0L

    /** Returns true when this fix should be saved as a node. [nowMillis] is wall-clock time. */
    fun shouldRecord(fix: Coordinate, speedKmh: Double, nowMillis: Long): Boolean {
        val current = anchor ?: run {
            reanchor(fix, nowMillis)
            lastNodeTime = nowMillis
            return true
        }
        val outside = distanceMeters(current, fix) >= 100
        if (isStopped) {
            if (!outside) { outsideCount = 0; return false }
            outsideCount += 1
            if (outsideCount < 2) return false
            isStopped = false
            outsideCount = 0
            reanchor(fix, nowMillis)
            lastNodeTime = nowMillis
            return true
        }
        if (outside) {
            reanchor(fix, nowMillis)
        } else if (nowMillis - anchorTime >= 300_000) {
            isStopped = true
            return false
        }
        if (nowMillis - lastNodeTime < recordingIntervalSeconds(speedKmh) * 1000) return false
        lastNodeTime = nowMillis
        return true
    }

    private fun reanchor(fix: Coordinate, nowMillis: Long) {
        anchor = fix
        anchorTime = nowMillis
    }
}
