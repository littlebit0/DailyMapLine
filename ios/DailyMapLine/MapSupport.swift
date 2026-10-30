import DailyMapLineCore
import MapLibre
import SwiftUI

enum MapStyle {
    /// Local style over the small bundled Seoul extract. The production map provider is still undecided.
    static let url: URL? = {
        guard let data = Bundle.main.url(forResource: "map", withExtension: "geojson") else { return nil }
        let filter: (String) -> [Any] = { ["has", $0] }
        let isLine: [Any] = ["==", ["geometry-type"], "LineString"]
        let isPolygon: [Any] = ["==", ["geometry-type"], "Polygon"]
        let roadCase: [String: Any] = ["line-color": "#d8d5ca", "line-width": ["interpolate", ["linear"], ["zoom"], 12, 1, 17, 11]]
        let road: [String: Any] = ["line-color": "#fffdf7", "line-width": ["interpolate", ["linear"], ["zoom"], 12, 0.6, 17, 8]]
        let round = ["line-cap": "round", "line-join": "round"]
        let highway: [Any] = ["all", isLine, filter("highway")]
        let style: [String: Any] = [
            "version": 8,
            "sources": ["local": ["type": "geojson", "data": data.absoluteString, "attribution": "© OpenStreetMap contributors"]],
            "layers": [
                ["id": "land", "type": "background", "paint": ["background-color": "#f2f0e9"]],
                ["id": "parks", "type": "fill", "source": "local", "filter": ["all", isPolygon, ["any", filter("leisure"), filter("landuse")]], "paint": ["fill-color": "#dce7cf"]],
                ["id": "water", "type": "fill", "source": "local", "filter": ["==", ["get", "natural"], "water"], "paint": ["fill-color": "#c1dce7"]],
                ["id": "stream", "type": "line", "source": "local", "filter": ["all", isLine, filter("waterway")], "paint": ["line-color": "#b6d9e8", "line-width": 5]],
                ["id": "buildings", "type": "fill", "source": "local", "filter": filter("building"), "paint": ["fill-color": "#dedbd4", "fill-outline-color": "#d2cfc7"]],
                ["id": "road-case", "type": "line", "source": "local", "filter": highway, "paint": roadCase, "layout": round],
                ["id": "roads", "type": "line", "source": "local", "filter": highway, "paint": road, "layout": round],
            ] as [[String: Any]],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: style),
              let folder = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let url = folder.appendingPathComponent("style.json")
        return (try? json.write(to: url)) == nil ? nil : url
    }()

    static let center = CLLocationCoordinate2D(latitude: 37.5682, longitude: 126.9795)
}

extension Coordinate {
    var location: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// Covers everything, then clears a 100 m wide stroke along each branch (50 m per side).
/// Stroking real paths keeps loop interiors covered unless buffers actually overlap there.
final class FogOverlay: UIView {
    weak var map: MLNMapView?
    var paths: [[Coordinate]] = [] { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let map else { return }
        context.setFillColor(UIColor(red: 0.443, green: 0.525, blue: 0.588, alpha: 0.67).cgColor)
        context.fill(bounds)
        context.setBlendMode(.clear)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for path in paths where path.count > 1 {
            context.setLineWidth(100 / map.metersPerPoint(atLatitude: path[0].lat))
            context.beginPath()
            for (index, coordinate) in path.enumerated() {
                let point = map.convert(coordinate.location, toPointTo: self)
                if index == 0 { context.move(to: point) } else { context.addLine(to: point) }
            }
            context.strokePath()
        }
    }
}

struct RouteMap: UIViewRepresentable {
    var branches: [Branch]
    var fog: Bool
    var fitsRoute = false

    private var paths: [[Coordinate]] { branches.map(\.path).filter { $0.count > 1 } }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let map = MLNMapView(frame: .zero, styleURL: MapStyle.url)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true
        map.compassView.isHidden = true
        map.setCenter(MapStyle.center, zoomLevel: 14.5, animated: false)
        container.addSubview(map)
        context.coordinator.map = map
        if fog {
            let overlay = FogOverlay()
            overlay.map = map
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(overlay)
            context.coordinator.overlay = overlay
        }
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.overlay?.paths = paths
        context.coordinator.update(paths, fit: fitsRoute)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var map: MLNMapView?
        weak var overlay: FogOverlay?
        private var source: MLNShapeSource?
        private var paths: [[Coordinate]] = []
        private var fit = false
        private var didFit = false

        func update(_ paths: [[Coordinate]], fit: Bool) {
            self.paths = paths
            self.fit = fit
            apply()
        }

        private func apply() {
            guard let source else { return }
            source.shape = MLNShapeCollectionFeature(shapes: paths.map { path in
                var coordinates = path.map(\.location)
                return MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
            })
            let points = paths.flatMap { $0 }.map(\.location)
            guard fit, !didFit, let map, !points.isEmpty, map.bounds.width > 0 else { return }
            didFit = true
            var coordinates = points
            map.setVisibleCoordinates(&coordinates, count: UInt(coordinates.count), edgePadding: UIEdgeInsets(top: 50, left: 40, bottom: 50, right: 40), animated: false)
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            let source = MLNShapeSource(identifier: "route", shape: nil, options: nil)
            style.addSource(source)
            for (id, color, width) in [("route-white", UIColor.white, 7.0), ("route-blue", UIColor(red: 0.141, green: 0.490, blue: 0.867, alpha: 1), 3.5)] {
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.lineColor = NSExpression(forConstantValue: color)
                layer.lineWidth = NSExpression(forConstantValue: width)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }
            self.source = source
            apply()
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) { overlay?.setNeedsDisplay() }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) { overlay?.setNeedsDisplay() }
    }
}
