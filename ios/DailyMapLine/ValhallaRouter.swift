import DailyMapLineCore
import Foundation
import Valhalla
import ValhallaConfigModels

/// On-device routing over Valhalla tiles built from the OSM South Korea extract.
final class ValhallaRouter: RoadRouting {
    // shortcut: a rectangle, so parts of North Korea, China and Tsushima inside it count as covered; use the extract polygon when regions are added.
    private static let coverage = (lon: 124.5...131.95, lat: 33.0...38.65)
    /// Same 80 m "a road is near" limit as before; Valhalla otherwise snaps up to 35 km away.
    private static let searchCutoff = 80
    private static let noSuitableEdges = 171

    private let valhalla: Valhalla

    init?(tiles: URL) {
        guard let config = try? ValhallaConfig(tileExtractTar: tiles), let valhalla = try? Valhalla(config) else { return nil }
        self.valhalla = valhalla
    }

    func route(from a: Coordinate, to b: Coordinate, speedKmh: Double) -> RouteResult {
        guard Self.isCovered(a), Self.isCovered(b) else { return .dataMissing }
        // Travel mode is not classified; speed only decides which road network to try first.
        for costing in speedKmh >= 25 ? ["auto", "pedestrian"] : ["pedestrian", "auto"] {
            if case .success(let path) = request(from: a, to: b, costing: costing), path.count > 1 {
                return .road(path)
            }
        }
        return .failed
    }

    func hasNoRoad(near point: Coordinate) -> Bool {
        guard Self.isCovered(point) else { return false }
        // Both networks must miss: walkways are not drivable and motorways are not walkable.
        return ["pedestrian", "auto"].allSatisfy {
            if case .failure(Self.noSuitableEdges) = request(from: point, to: point, costing: $0) { return true }
            return false
        }
    }

    private static func isCovered(_ point: Coordinate) -> Bool {
        coverage.lon.contains(point.lon) && coverage.lat.contains(point.lat)
    }

    private enum Outcome {
        case success([Coordinate])
        case failure(Int)
    }

    private func request(from a: Coordinate, to b: Coordinate, costing: String) -> Outcome {
        let location: (Coordinate) -> [String: Any] = {
            ["lat": $0.lat, "lon": $0.lon, "search_cutoff": Self.searchCutoff, "minimum_reachability": 0]
        }
        let body: [String: Any] = [
            "locations": [location(a), location(b)],
            "costing": costing,
            "directions_type": "none",
        ]
        do {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            let response = try valhalla.route(rawRequest: json)
            guard let object = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                  let legs = (object["trip"] as? [String: Any])?["legs"] as? [[String: Any]] else { return .failure(-1) }
            let path = legs.compactMap { $0["shape"] as? String }.flatMap { decodePolyline6($0) }
            return .success(path)
        } catch ValhallaError.valhallaError(let code, _) {
            return .failure(code)
        } catch {
            return .failure(-1)
        }
    }
}
