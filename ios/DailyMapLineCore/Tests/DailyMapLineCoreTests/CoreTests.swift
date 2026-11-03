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

@Test func timelineLastsTwentySecondsAndSkipsGaps() {
    let a = Coordinate(lon: 127, lat: 37), b = Coordinate(lon: 127.02, lat: 37), c = Coordinate(lon: 127.04, lat: 37)
    let length = distanceMeters(a, b)
    let branches = [
        Branch(from: 1, to: 2, state: .road, path: [a, b]),
        Branch(from: 2, to: 3, state: .gap, path: []),
        Branch(from: 3, to: 4, state: .road, path: [b, c]),
    ]
    let timeline = VideoTimeline(branches: branches)
    #expect(abs(timeline.lengthMeters - length * 2) < 0.001)
    #expect(timeline.durationSeconds == 20)
    #expect(VideoTimeline(branches: []).durationSeconds == 0)
    #expect(timeline.traces(upTo: 0).isEmpty)
    #expect(timeline.traces(upTo: length * 2).count == 1)
    #expect(timeline.frame(at: length / 2)?.targetScaleKm ?? 0 > 1)
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

@Test func dateRangeIncludesBothEndsInRecordingOrder() throws {
    let (store, path, _, _) = try twoDayStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try store.record(sample[3], date: "2026-11-03", router: try prototypeRouter())
    let range = try store.branches(from: "2026-10-31", to: "2026-11-01")
    #expect(range == (try store.branches(date: "2026-10-31")) + (try store.branches(date: "2026-11-01")))
    #expect(try store.branches(from: "2026-10-31", to: "2026-11-03").count == 3)
    #expect(try store.branches(from: "2026-11-02", to: "2026-11-02").isEmpty)
}

@Test func noRoadIsOnlyJudgedInsideCoveredArea() throws {
    let json = #"{"nodes":{"1":[127,37],"2":[127.001,37]},"ways":[{"nodes":["1","2"]}]}"#
    let covered = try RoadRouter(json: Data(json.utf8), coverage: (lon: 126.9...127.1, lat: 36.9...37.1))
    #expect(covered.hasNoRoad(near: Coordinate(lon: 127, lat: 37.01)))
    #expect(!covered.hasNoRoad(near: Coordinate(lon: 127, lat: 37)))
    #expect(!covered.hasNoRoad(near: Coordinate(lon: 128, lat: 38)))
    let unknown = try RoadRouter(json: Data(json.utf8))
    #expect(!unknown.hasNoRoad(near: Coordinate(lon: 127, lat: 37.01)))
}

@Test func branchesNeverGetStraightLines() throws {
    let json = #"{"nodes":{"1":[127,37],"2":[127.001,37]},"ways":[{"nodes":["1","2"]}]}"#
    let router = try RoadRouter(json: Data(json.utf8), coverage: (lon: 126.9...127.1, lat: 36.9...37.1))
    let (store, path) = try temporaryStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try store.record(Coordinate(lon: 127, lat: 37), date: "2026-10-31", router: router)
    try store.record(Coordinate(lon: 127, lat: 37.01), date: "2026-10-31", router: router, afterGap: true)
    try store.record(Coordinate(lon: 128, lat: 38), date: "2026-10-31", router: router)
    let branches = try store.branches(date: "2026-10-31")
    #expect(branches.map { $0.state } == [.gap, .dataMissing])
    #expect(branches.allSatisfy { $0.path.isEmpty })
}

@Test func backupRestoreReplacesRecordsExactly() throws {
    let (source, sourcePath, _, b) = try twoDayStore()
    defer { try? FileManager.default.removeItem(atPath: sourcePath) }
    try source.deleteDay(date: "2026-10-31")
    let backup = try source.exportBackup()
    #expect(try RecordStore.inspectBackup(backup) == BackupSummary(dates: ["2026-11-01"], nodeCount: 2, branchCount: 1))
    let (target, targetPath) = try temporaryStore()
    defer { try? FileManager.default.removeItem(atPath: targetPath) }
    try target.record(sample[4], date: "2026-12-25", router: nil)
    try target.restoreBackup(backup)
    #expect(try target.recordedDates() == ["2026-11-01"])
    #expect(try target.nodes(date: "2026-11-01") == [b])
    #expect(try target.branches(date: "2026-11-01") == source.branches(date: "2026-11-01"))
    let next = try target.record(sample[0], date: "2026-11-02", router: nil, afterGap: true)
    #expect(next.id > b.id)
}

@Test func damagedBackupIsRejectedAndKeepsRecords() throws {
    let (store, path, a, _) = try twoDayStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    var backup = try store.exportBackup()
    backup[backup.count - 1] ^= 0xFF
    #expect(throws: StoreError.self) { try store.restoreBackup(backup) }
    #expect(throws: StoreError.self) { try RecordStore.inspectBackup(Data("not a backup".utf8)) }
    #expect(try store.nodes(date: "2026-10-31").last == a)
    #expect(try store.recordedDates().count == 2)
}

@Test func polyline6Decodes() {
    // Valhalla's documented example encoding of (lat 38.5, lon -120.2), (40.7, -120.95), (43.252, -126.453) at 1e6.
    let path = decodePolyline6("_izlhA~rlgdF_{geC~ywl@_kwzCn`{nI")
    #expect(path == [Coordinate(lon: -120.2, lat: 38.5), Coordinate(lon: -120.95, lat: 40.7), Coordinate(lon: -126.453, lat: 43.252)])
}

@Test func recalculationConnectsOnlyMissingBranches() throws {
    let (store, path) = try temporaryStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try store.record(sample[0], date: "2026-10-31", router: nil)
    try store.record(sample[1], date: "2026-10-31", router: nil)
    try store.record(sample[2], date: "2026-10-31", router: nil, afterGap: true)
    #expect(try store.branches(date: "2026-10-31").map { $0.state } == [.dataMissing, .gap])
    #expect(try store.recalculateUnconnected(router: try prototypeRouter()) == 1)
    let branches = try store.branches(date: "2026-10-31")
    #expect(branches.map { $0.state } == [.road, .gap])
    #expect(branches[0].path.count > 2)
}

@Test func travelTimeEstimateMatchesRecordingIntervals() {
    #expect(estimatedTravelSeconds(lengthMeters: 300) == 300)
    #expect(estimatedTravelSeconds(lengthMeters: 900) == 180)
    #expect(estimatedTravelSeconds(lengthMeters: 1_500) == 120)
    #expect(estimatedTravelSeconds(lengthMeters: 5_000) == 60)
}

@Test func replayFollowsEstimatedTravelTime() {
    let walkEnd = Coordinate(lon: 127.003, lat: 37)
    let driveEnd = Coordinate(lon: 127.103, lat: 37)
    let walk = Branch(from: 1, to: 2, state: .road, path: [Coordinate(lon: 127, lat: 37), walkEnd])
    let drive = Branch(from: 2, to: 3, state: .road, path: [walkEnd, driveEnd])
    let timeline = VideoTimeline(branches: [walk, drive])
    let walkLength = distanceMeters(walk.path[0], walkEnd)
    // The 267 m walk takes 300 s and the 9 km drive 60 s, so the walk gets 300/360 of the video.
    #expect(abs(timeline.position(at: 300.0 / 360) - walkLength) < 0.01)
    #expect(abs(timeline.position(at: 1) - timeline.lengthMeters) < 0.01)
    let walkScale = timeline.frame(at: walkLength / 2)?.targetScaleKm ?? 0
    let driveScale = timeline.frame(at: walkLength + 4_500)?.targetScaleKm ?? 0
    #expect(walkScale == 1)
    #expect(driveScale > 8)
    #expect(driveScale <= 30)
}
