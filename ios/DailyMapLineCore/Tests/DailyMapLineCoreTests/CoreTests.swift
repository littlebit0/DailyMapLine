import Foundation
import Testing
@testable import DailyMapLineCore

@Test func speedBoundaries() {
    #expect(recordingInterval(speedKmh: 6.99) == 300)
    #expect(recordingInterval(speedKmh: 7) == 180)
    #expect(recordingInterval(speedKmh: 25) == 120)
    #expect(recordingInterval(speedKmh: 60) == 90)
    #expect(recordingInterval(speedKmh: 80) == 60)
}

@Test func scaleBoundaries() {
    #expect(scaleKm(branchLengthMeters: 1000) == 1)
    #expect(scaleKm(branchLengthMeters: 1001) == 1.5)
    #expect(scaleKm(branchLengthMeters: 20001) == 30)
    #expect(scaleKm(branchLengthMeters: 99999) == 30)
}

@Test func rightAngleIsATurnAndStraightIsNot() {
    let path = [Coordinate(lon: 127, lat: 37), Coordinate(lon: 127.001, lat: 37), Coordinate(lon: 127.002, lat: 37), Coordinate(lon: 127.002, lat: 37.001)]
    let turns = directionChanges(path)
    #expect(turns.count == 1)
    #expect(turns[0].coordinate == path[2])
}

@Test func stopsAfterFiveMinutesAndResumesOnSecondOutsideFix() {
    var policy = RecordingPolicy()
    let origin = Coordinate(lon: 127, lat: 37)
    let far = Coordinate(lon: 127.01, lat: 37)
    let t0 = Date(timeIntervalSince1970: 0)
    var results: [Bool] = []
    results.append(policy.shouldRecord(origin, speedKmh: 0, at: t0))
    results.append(policy.shouldRecord(origin, speedKmh: 0, at: t0.addingTimeInterval(300)))
    #expect(policy.isStopped)
    results.append(policy.shouldRecord(far, speedKmh: 30, at: t0.addingTimeInterval(400)))
    results.append(policy.shouldRecord(far, speedKmh: 30, at: t0.addingTimeInterval(410)))
    #expect(results == [true, false, false, true])
    #expect(!policy.isStopped)
}

@Test func movingRespectsSpeedInterval() {
    var policy = RecordingPolicy()
    let t0 = Date(timeIntervalSince1970: 0)
    var results: [Bool] = []
    results.append(policy.shouldRecord(Coordinate(lon: 127, lat: 37), speedKmh: 90, at: t0))
    results.append(policy.shouldRecord(Coordinate(lon: 127.01, lat: 37), speedKmh: 90, at: t0.addingTimeInterval(59)))
    results.append(policy.shouldRecord(Coordinate(lon: 127.02, lat: 37), speedKmh: 90, at: t0.addingTimeInterval(60)))
    #expect(results == [true, false, true])
}

private let sample = [
    Coordinate(lon: 126.9774, lat: 37.5664), Coordinate(lon: 126.9770, lat: 37.5701),
    Coordinate(lon: 126.9831, lat: 37.5703), Coordinate(lon: 126.9826, lat: 37.5662),
    Coordinate(lon: 126.9774, lat: 37.5664),
]

private func prototypeRouter() throws -> RoadRouter {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("prototype/public/data/roads.json")
    return try RoadRouter(json: Data(contentsOf: url))
}

private func temporaryStore() throws -> (RecordStore, String) {
    let path = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
    return (try RecordStore(path: path), path)
}

@Test func routeLengthMatchesApprovedPrototype() throws {
    let (store, path) = try temporaryStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let router = try prototypeRouter()
    for point in sample { try store.record(point, date: "2026-10-31", router: router) }
    let branches = try store.branches(date: "2026-10-31")
    #expect(branches.count == 4)
    #expect(branches.allSatisfy { $0.state == .road })
    let total = branches.map { cumulativeDistances($0.path).last ?? 0 }.reduce(0, +)
    #expect(abs(total - 2095.6568) < 0.01)
}

@Test func missingDataKeepsNodeAndDoesNotConnectStraight() throws {
    let (store, path) = try temporaryStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let router = try prototypeRouter()
    try store.record(sample[0], date: "2026-10-31", router: router)
    try store.record(Coordinate(lon: 0, lat: 0), date: "2026-10-31", router: router)
    #expect(try store.nodes(date: "2026-10-31").count == 2)
    let branch = try #require(try store.branches(date: "2026-10-31").first)
    #expect(branch.state == .dataMissing)
    #expect(branch.path.isEmpty)
}

@Test func nextDayStartsFromPreviousLastNodeWithoutDuplicate() throws {
    let (store, path) = try temporaryStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let router = try prototypeRouter()
    let a = try store.record(sample[0], date: "2026-10-31", router: router)
    let b = try store.record(sample[1], date: "2026-11-01", router: router)
    #expect(try store.nodes(date: "2026-11-01") == [b])
    #expect(try store.branches(date: "2026-10-31").isEmpty)
    let branch = try #require(try store.branches(date: "2026-11-01").first)
    #expect(branch.from == a.id && branch.to == b.id)
    #expect(try store.recordedDates() == ["2026-10-31", "2026-11-01"])
}

@Test func gapIsNeverRouted() throws {
    let (store, path) = try temporaryStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let router = try prototypeRouter()
    try store.record(sample[0], date: "2026-10-31", router: router)
    try store.record(sample[1], date: "2026-10-31", router: router, afterGap: true)
    let branch = try #require(try store.branches(date: "2026-10-31").first)
    #expect(branch.state == .gap && branch.path.isEmpty)
}

@Test func recordsSurviveReopen() throws {
    let (store, path) = try temporaryStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let node = try store.record(sample[0], date: "2026-10-31", router: nil)
    let reopened = try RecordStore(path: path)
    #expect(try reopened.nodes(date: "2026-10-31") == [node])
}

@Test func timelineUsesOneSecondPerKmAndSkipsGaps() {
    let a = Coordinate(lon: 127, lat: 37), b = Coordinate(lon: 127.02, lat: 37), c = Coordinate(lon: 127.04, lat: 37)
    let length = distanceMeters(a, b)
    let branches = [
        Branch(from: 1, to: 2, state: .road, path: [a, b]),
        Branch(from: 2, to: 3, state: .gap, path: []),
        Branch(from: 3, to: 4, state: .road, path: [b, c]),
    ]
    let timeline = VideoTimeline(branches: branches)
    #expect(timeline.runs.count == 2)
    #expect(abs(timeline.durationSeconds - length * 2 / 1000) < 0.001)
    let trimmed = VideoTimeline(branches: branches, trimStartMeters: 100, trimEndMeters: 200)
    #expect(abs(trimmed.lengthMeters - (length * 2 - 300)) < 0.001)
    #expect(trimmed.traces(upTo: 50).isEmpty)
    #expect(trimmed.frame(at: length / 2)?.targetScaleKm ?? 0 > 1)
}

private func twoDayStore() throws -> (RecordStore, String, a: Node, b: Node) {
    let (store, path) = try temporaryStore()
    let router = try prototypeRouter()
    try store.record(sample[0], date: "2026-10-31", router: router)
    let a = try store.record(sample[1], date: "2026-10-31", router: router)
    let b = try store.record(sample[2], date: "2026-11-01", router: router)
    return (store, path, a, b)
}

@Test func deletingDayKeepsBoundaryNodeAndNextDayConnection() throws {
    let (store, path, a, b) = try twoDayStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let preview = try store.deletionPreview(date: "2026-10-31")
    #expect(preview == DeletionPreview(deletedNodes: 1, deletedBranches: 1, retainedNodes: 1, referencedBy: ["2026-11-01"]))
    let kept = try store.branches(date: "2026-11-01")
    try store.deleteDay(date: "2026-10-31")
    #expect(try store.recordedDates() == ["2026-11-01"])
    #expect(try store.nodes(date: "2026-10-31").isEmpty)
    #expect(try store.branches(date: "2026-10-31").isEmpty)
    #expect(try store.nodes(date: "2026-11-01") == [b])
    #expect(try store.branches(date: "2026-11-01") == kept)
    #expect(kept[0].from == a.id)
}

@Test func deletingNextDayAlsoRemovesRetainedBoundaryNode() throws {
    let (store, path, a, _) = try twoDayStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try store.deleteDay(date: "2026-10-31")
    try store.deleteDay(date: "2026-11-01")
    #expect(try store.recordedDates().isEmpty)
    #expect(try store.lastNode() == nil)
    #expect(a.id > 0)
}

@Test func deletingNextDayLeavesPreviousDayIntact() throws {
    let (store, path, a, _) = try twoDayStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let preview = try store.deletionPreview(date: "2026-11-01")
    #expect(preview == DeletionPreview(deletedNodes: 1, deletedBranches: 1, retainedNodes: 0, referencedBy: []))
    try store.deleteDay(date: "2026-11-01")
    #expect(try store.recordedDates() == ["2026-10-31"])
    #expect(try store.nodes(date: "2026-10-31").last == a)
    #expect(try store.branches(date: "2026-10-31").count == 1)
}

@Test func gapDoesNotKeepBoundaryNode() throws {
    let (store, path) = try temporaryStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let router = try prototypeRouter()
    try store.record(sample[0], date: "2026-10-31", router: router)
    let b = try store.record(sample[1], date: "2026-11-01", router: router, afterGap: true)
    #expect(try store.deletionPreview(date: "2026-10-31").retainedNodes == 0)
    try store.deleteDay(date: "2026-10-31")
    #expect(try store.recordedDates() == ["2026-11-01"])
    #expect(try store.nodes(date: "2026-11-01") == [b])
    #expect(try store.branches(date: "2026-11-01").isEmpty)
}

@Test func redeletingAfterNewRecordsOnSameDateKeepsBoundary() throws {
    let (store, path, _, b) = try twoDayStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try store.deleteDay(date: "2026-10-31")
    let c = try store.record(sample[3], date: "2026-10-31", router: nil, afterGap: true)
    #expect(try store.nodes(date: "2026-10-31") == [c])
    try store.deleteDay(date: "2026-10-31")
    #expect(try store.nodes(date: "2026-11-01") == [b])
    #expect(try store.branches(date: "2026-11-01").count == 1)
    #expect(try store.lastNode() == b)
}
