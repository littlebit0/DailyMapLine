import Foundation

public enum RouteResult: Equatable, Sendable {
    case road([Coordinate])
    /// Outside the area the road data covers. Missing data is never treated as "no road exists".
    case dataMissing
    case failed
}

/// Road routing between consecutive nodes. Branches only ever follow roads.
public protocol RoadRouting {
    /// `speedKmh` is the transient measured speed; it may pick a costing but is never stored.
    func route(from a: Coordinate, to b: Coordinate, speedKmh: Double) -> RouteResult
    /// True only where road data exists and shows no road nearby.
    func hasNoRoad(near point: Coordinate) -> Bool
}

/// Decodes Valhalla's encoded polyline with six digits of precision.
public func decodePolyline6(_ encoded: String) -> [Coordinate] {
    var coordinates: [Coordinate] = []
    var index = encoded.unicodeScalars.startIndex
    let scalars = encoded.unicodeScalars
    var lat = 0, lon = 0
    func next() -> Int? {
        var result = 0, shift = 0
        while index < scalars.endIndex {
            let byte = Int(scalars[index].value) - 63
            index = scalars.index(after: index)
            result |= (byte & 0x1F) << shift
            shift += 5
            if byte < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
        }
        return nil
    }
    while index < scalars.endIndex, let dLat = next(), let dLon = next() {
        lat += dLat
        lon += dLon
        coordinates.append(Coordinate(lon: Double(lon) / 1e6, lat: Double(lat) / 1e6))
    }
    return coordinates
}
