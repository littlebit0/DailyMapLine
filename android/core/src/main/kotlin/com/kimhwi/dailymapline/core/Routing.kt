package com.kimhwi.dailymapline.core

sealed interface RouteResult {
    data class Road(val path: List<Coordinate>) : RouteResult
    /** Outside the area the road data covers. Missing data is never treated as "no road exists". */
    data object DataMissing : RouteResult
    data object Failed : RouteResult
}

/** Road routing between consecutive nodes. Branches only ever follow roads. */
interface RoadRouting {
    /** [speedKmh] is the transient measured speed; it may pick a costing but is never stored. */
    fun route(from: Coordinate, to: Coordinate, speedKmh: Double): RouteResult
    /** True only where road data exists and shows no road nearby. */
    fun hasNoRoad(near: Coordinate): Boolean
}

enum class BranchState(val raw: String) {
    Road("road"), DataMissing("dataMissing"), Failed("failed"), Gap("gap");

    companion object {
        fun of(raw: String) = entries.first { it.raw == raw }
    }
}

data class Branch(val from: Long, val to: Long, val state: BranchState, val path: List<Coordinate>)
