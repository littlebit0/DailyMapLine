import Foundation

public enum RouteResult: Equatable, Sendable {
    case road([Coordinate])
    /// Outside the area the road data covers. Missing data is never treated as "no road exists".
    case dataMissing
    case failed
}

/// Shortest-path estimate over bundled road data, ported from the prototype. It is not the observed trip.
/// No direction, access or vehicle rules. The production routing engine is still undecided.
public struct RoadRouter: Sendable {
    private struct Edge: Sendable { let to: String; let cost: Double }
    private struct Payload: Decodable {
        let nodes: [String: [Double]]
        let ways: [Way]
        struct Way: Decodable { let nodes: [String] }
    }

    private let nodes: [String: Coordinate]
    private let edges: [String: [Edge]]
    private let snapLimit: Double
    private let coverage: (lon: ClosedRange<Double>, lat: ClosedRange<Double>)?

    /// Without `coverage`, no location can be judged road-free.
    public init(json: Data, snapLimit: Double = 80, coverage: (lon: ClosedRange<Double>, lat: ClosedRange<Double>)? = nil) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: json)
        var nodes: [String: Coordinate] = [:]
        for (id, value) in payload.nodes where value.count == 2 {
            nodes[id] = Coordinate(lon: value[0], lat: value[1])
        }
        var edges: [String: [Edge]] = [:]
        for way in payload.ways {
            for (a, b) in zip(way.nodes, way.nodes.dropFirst()) where a != b {
                guard let pa = nodes[a], let pb = nodes[b] else { continue }
                let cost = distanceMeters(pa, pb)
                edges[a, default: []].append(Edge(to: b, cost: cost))
                edges[b, default: []].append(Edge(to: a, cost: cost))
            }
        }
        self.nodes = nodes
        self.edges = edges
        self.snapLimit = snapLimit
        self.coverage = coverage
    }

    public func route(from a: Coordinate, to b: Coordinate) -> RouteResult {
        guard let start = nearest(a), let end = nearest(b) else { return .dataMissing }
        guard let ids = findPath(start, end) else { return .failed }
        return .road(ids.compactMap { nodes[$0] })
    }

    /// True only inside the covered area, so missing data is never read as "no road exists".
    public func hasNoRoad(near point: Coordinate) -> Bool {
        guard let coverage, coverage.lon.contains(point.lon), coverage.lat.contains(point.lat) else { return false }
        return nearest(point) == nil
    }

    private func nearest(_ point: Coordinate) -> String? {
        var best: String?
        var bestDistance = snapLimit
        for (id, coordinate) in nodes {
            let distance = distanceMeters(point, coordinate)
            if distance <= bestDistance {
                best = id
                bestDistance = distance
            }
        }
        return best
    }

    // shortcut: linear open-set scan is fine for the small bundled graph, replace with the production engine.
    private func findPath(_ start: String, _ end: String) -> [String]? {
        guard let goal = nodes[end], let origin = nodes[start] else { return nil }
        var costs = [start: 0.0]
        var parents: [String: String] = [:]
        var open: [(id: String, cost: Double, rank: Double)] = [(start, 0, distanceMeters(origin, goal))]
        while let index = open.indices.min(by: { open[$0].rank < open[$1].rank }) {
            let current = open.remove(at: index)
            if current.cost > costs[current.id]! { continue }
            if current.id == end {
                var ids = [end]
                while let parent = parents[ids[0]] { ids.insert(parent, at: 0) }
                return ids
            }
            for edge in edges[current.id] ?? [] {
                let cost = current.cost + edge.cost
                if cost >= costs[edge.to] ?? .infinity { continue }
                costs[edge.to] = cost
                parents[edge.to] = current.id
                open.append((edge.to, cost, cost + distanceMeters(nodes[edge.to]!, goal)))
            }
        }
        return nil
    }
}
