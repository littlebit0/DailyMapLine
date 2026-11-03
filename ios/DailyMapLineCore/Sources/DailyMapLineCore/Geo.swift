import Foundation

public struct Coordinate: Codable, Equatable, Hashable, Sendable {
    public var lon: Double
    public var lat: Double
    public init(lon: Double, lat: Double) {
        self.lon = lon
        self.lat = lat
    }
}

/// Every record video lasts this long whatever the distance (user decision, replacing 1 s per km).
public let videoDurationSeconds = 20.0

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

/// Real travel time a branch most likely took, from its length alone (no timestamps are stored).
/// Nodes are recorded at speed-dependent intervals, so the interval consistent with
/// length / interval is the best estimate: under 583 m 300 s, under 1,250 m 180 s,
/// under 2,000 m 120 s, otherwise 60 s.
public func estimatedTravelSeconds(lengthMeters: Double) -> Double {
    for seconds in [300.0, 180, 120, 90, 60] where recordingInterval(speedKmh: lengthMeters / seconds * 3.6) == seconds {
        return seconds
    }
    return 60
}

/// Video playback over road branches only. Gaps and unconnected branches are skipped, never bridged.
/// The fixed video length is shared by estimated real travel time, so the replay keeps the rhythm of
/// the day: walking moves slowly on screen, driving quickly. The camera zooms out with on-screen speed.
public struct VideoTimeline: Sendable {
    public struct Frame: Equatable, Sendable {
        public var center: Coordinate
        public var targetScaleKm: Double
    }

    private struct Segment: Sendable {
        let path: [Coordinate]
        let cumulative: [Double]
        let offset: Double
        let length: Double
        let timeOffset: Double
        let time: Double
    }

    /// Map width the 360 pt frame shows per km of scale bar (57 pt per bar).
    private static let metersPerFrameWidthPerKm = 1000 / 57 * 360.0
    /// Keeps the moving point from crossing more than a third of the frame per second.
    private static let maxFrameWidthsPerSecond = 1 / 3.0

    public let lengthMeters: Double
    private let segments: [Segment]
    private let totalTime: Double

    public init(branches: [Branch]) {
        var offset = 0.0, time = 0.0
        var segments: [Segment] = []
        for branch in branches where branch.state == .road {
            let cumulative = cumulativeDistances(branch.path)
            guard let length = cumulative.last, length > 0 else { continue }
            let seconds = estimatedTravelSeconds(lengthMeters: length)
            segments.append(Segment(path: branch.path, cumulative: cumulative, offset: offset, length: length, timeOffset: time, time: seconds))
            offset += length
            time += seconds
        }
        self.segments = segments
        lengthMeters = offset
        totalTime = time
    }

    public var durationSeconds: Double { lengthMeters > 0 ? videoDurationSeconds : 0 }

    /// Position in meters for a playback fraction 0...1, following estimated travel time.
    public func position(at fraction: Double) -> Double {
        let time = max(0, min(1, fraction)) * totalTime
        guard let segment = segments.first(where: { time <= $0.timeOffset + $0.time }) ?? segments.last else { return 0 }
        return segment.offset + segment.length * max(0, min(1, (time - segment.timeOffset) / segment.time))
    }

    public func frame(at position: Double) -> Frame? {
        guard let segment = segments.first(where: { position <= $0.offset + $0.length }) ?? segments.last else { return nil }
        let local = max(0, min(segment.length, position - segment.offset))
        let progress = local / segment.length
        let transition = max(0, min(1, progress / 0.15, (1 - progress) / 0.15))
        let byLength = 1 + (scaleKm(branchLengthMeters: segment.length) - 1) * transition
        let metersPerVideoSecond = segment.length / (segment.time / totalTime * videoDurationSeconds)
        let bySpeed = metersPerVideoSecond / Self.maxFrameWidthsPerSecond / Self.metersPerFrameWidthPerKm
        return Frame(center: point(on: segment.path, segment.cumulative, at: local), targetScaleKm: min(30, max(byLength, bySpeed)))
    }

    /// Lines drawn so far.
    public func traces(upTo position: Double) -> [[Coordinate]] {
        var traces: [[Coordinate]] = []
        for segment in segments where segment.offset <= position {
            let to = min(segment.length, position - segment.offset)
            guard to > 0 else { continue }
            var slice = [segment.path[0]]
            for (i, d) in segment.cumulative.enumerated() where d > 0 && d < to { slice.append(segment.path[i]) }
            slice.append(point(on: segment.path, segment.cumulative, at: to))
            if let last = traces.last?.last, last == slice.first {
                traces[traces.count - 1] += slice.dropFirst()
            } else {
                traces.append(slice)
            }
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
