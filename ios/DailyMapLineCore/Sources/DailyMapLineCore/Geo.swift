import Foundation

public struct Coordinate: Codable, Equatable, Hashable, Sendable {
    public var lon: Double
    public var lat: Double
    public init(lon: Double, lat: Double) {
        self.lon = lon
        self.lat = lat
    }
}

/// Approved prototype speed: 1 km per second (5x the original 5 s/km plan).
public let videoSecondsPerKm = 1.0

public func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
    let rad = Double.pi / 180
    let dLat = (b.lat - a.lat) * rad
    let dLon = (b.lon - a.lon) * rad
    let h = pow(sin(dLat / 2), 2) + cos(a.lat * rad) * cos(b.lat * rad) * pow(sin(dLon / 2), 2)
    return 6371008.8 * 2 * atan2(h.squareRoot(), (1 - h).squareRoot())
}

public func cumulativeDistances(_ path: [Coordinate]) -> [Double] {
    var result = path.isEmpty ? [] : [0.0]
    for i in path.indices.dropFirst() {
        result.append(result[i - 1] + distanceMeters(path[i - 1], path[i]))
    }
    return result
}

public struct Turn: Equatable, Sendable {
    public var coordinate: Coordinate
    public var angle: Double
    public var distance: Double
}

/// Display-only turn markers; these are not recorded location nodes.
public func directionChanges(_ path: [Coordinate], threshold: Double = 25) -> [Turn] {
    guard path.count > 2 else { return [] }
    let cumulative = cumulativeDistances(path)
    var turns: [Turn] = []
    for i in 1..<(path.count - 1) {
        let p = path[i]
        let scale = cos(p.lat * .pi / 180)
        let a = ((p.lon - path[i - 1].lon) * scale, p.lat - path[i - 1].lat)
        let b = ((path[i + 1].lon - p.lon) * scale, path[i + 1].lat - p.lat)
        let lengths = hypot(a.0, a.1) * hypot(b.0, b.1)
        if hypot(a.0, a.1) < 1e-10 || hypot(b.0, b.1) < 1e-10 { continue }
        let cosine = max(-1, min(1, (a.0 * b.0 + a.1 * b.1) / lengths))
        let angle = acos(cosine) * 180 / .pi
        if angle >= threshold { turns.append(Turn(coordinate: p, angle: angle, distance: cumulative[i])) }
    }
    return turns
}

public func scaleKm(branchLengthMeters length: Double) -> Double {
    [1, 1.5, 2, 3, 4, 5, 8, 12, 20, 30].first { length <= $0 * 1000 } ?? 30
}

public func recordingInterval(speedKmh speed: Double) -> TimeInterval {
    switch speed {
    case ..<7: 300
    case ..<25: 180
    case ..<60: 120
    case ..<80: 90
    default: 60
    }
}

/// Video playback over connected branches only. Gaps and unconnected branches are skipped, never bridged.
public struct VideoTimeline: Sendable {
    public struct Frame: Equatable, Sendable {
        public var center: Coordinate
        public var targetScaleKm: Double
    }

    public let runs: [[Coordinate]]
    public let start: Double
    public let end: Double
    private let segments: [(path: [Coordinate], cumulative: [Double], offset: Double, length: Double)]

    public init(branches: [Branch], trimStartMeters: Double = 0, trimEndMeters: Double = 0) {
        var offset = 0.0
        var segments: [(path: [Coordinate], cumulative: [Double], offset: Double, length: Double)] = []
        var runs: [[Coordinate]] = []
        var previousEnd: Int64?
        for branch in branches where branch.state == .road || branch.state == .direct {
            let cumulative = cumulativeDistances(branch.path)
            guard let length = cumulative.last, length > 0 else { continue }
            segments.append((branch.path, cumulative, offset, length))
            offset += length
            if previousEnd == branch.from, !runs.isEmpty {
                runs[runs.count - 1] += branch.path.dropFirst()
            } else {
                runs.append(branch.path)
            }
            previousEnd = branch.to
        }
        self.segments = segments
        self.runs = runs
        start = min(max(0, trimStartMeters), offset)
        end = max(start, offset - max(0, trimEndMeters))
    }

    public var lengthMeters: Double { end - start }
    public var durationSeconds: Double { lengthMeters / 1000 * videoSecondsPerKm }

    /// Position in meters along all connected branches for a playback fraction 0...1.
    public func position(at fraction: Double) -> Double { start + lengthMeters * fraction }

    public func frame(at position: Double) -> Frame? {
        guard let segment = segments.first(where: { position <= $0.offset + $0.length }) ?? segments.last else { return nil }
        let local = max(0, min(segment.length, position - segment.offset))
        let progress = local / segment.length
        let transition = max(0, min(1, progress / 0.15, (1 - progress) / 0.15))
        let target = scaleKm(branchLengthMeters: segment.length)
        return Frame(center: point(on: segment.path, segment.cumulative, at: local), targetScaleKm: 1 + (target - 1) * transition)
    }

    /// Lines drawn so far, respecting the trimmed start.
    public func traces(upTo position: Double) -> [[Coordinate]] {
        var traces: [[Coordinate]] = []
        var joined = false
        for segment in segments where segment.offset <= position && segment.offset + segment.length >= start {
            let from = max(0, start - segment.offset)
            let to = min(segment.length, position - segment.offset)
            guard to > from else { continue }
            var slice = [point(on: segment.path, segment.cumulative, at: from)]
            for (i, d) in segment.cumulative.enumerated() where d > from && d < to { slice.append(segment.path[i]) }
            slice.append(point(on: segment.path, segment.cumulative, at: to))
            if joined, traces[traces.count - 1].last == slice.first {
                traces[traces.count - 1] += slice.dropFirst()
            } else {
                traces.append(slice)
            }
            joined = true
        }
        return traces
    }

    private func point(on path: [Coordinate], _ cumulative: [Double], at distance: Double) -> Coordinate {
        var i = 1
        while i < cumulative.count - 1, cumulative[i] < distance { i += 1 }
        let span = cumulative[i] - cumulative[i - 1]
        let ratio = span > 0 ? (distance - cumulative[i - 1]) / span : 0
        return Coordinate(lon: path[i - 1].lon + (path[i].lon - path[i - 1].lon) * ratio, lat: path[i - 1].lat + (path[i].lat - path[i - 1].lat) * ratio)
    }
}
