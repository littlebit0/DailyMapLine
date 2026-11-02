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

    public let lengthMeters: Double
    private let segments: [(path: [Coordinate], cumulative: [Double], offset: Double, length: Double)]

    public init(branches: [Branch]) {
        var offset = 0.0
        var segments: [(path: [Coordinate], cumulative: [Double], offset: Double, length: Double)] = []
        for branch in branches where branch.state == .road {
            let cumulative = cumulativeDistances(branch.path)
            guard let length = cumulative.last, length > 0 else { continue }
            segments.append((branch.path, cumulative, offset, length))
            offset += length
        }
        self.segments = segments
        lengthMeters = offset
    }

    public var durationSeconds: Double { lengthMeters / 1000 * videoSecondsPerKm }

    /// Position in meters along all connected branches for a playback fraction 0...1.
    public func position(at fraction: Double) -> Double { lengthMeters * fraction }

    public func frame(at position: Double) -> Frame? {
        guard let segment = segments.first(where: { position <= $0.offset + $0.length }) ?? segments.last else { return nil }
        let local = max(0, min(segment.length, position - segment.offset))
        let progress = local / segment.length
        let transition = max(0, min(1, progress / 0.15, (1 - progress) / 0.15))
        let target = scaleKm(branchLengthMeters: segment.length)
        return Frame(center: point(on: segment.path, segment.cumulative, at: local), targetScaleKm: 1 + (target - 1) * transition)
    }

    /// Lines drawn so far.
    public func traces(upTo position: Double) -> [[Coordinate]] {
        var traces: [[Coordinate]] = []
        var joined = false
        for segment in segments where segment.offset <= position {
            let to = min(segment.length, position - segment.offset)
            guard to > 0 else { continue }
            var slice = [segment.path[0]]
            for (i, d) in segment.cumulative.enumerated() where d > 0 && d < to { slice.append(segment.path[i]) }
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
