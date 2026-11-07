import DailyMapLineCore
import MapLibre
import SwiftUI

/// Route preview on the record video screen: branch lines only.
struct RecordRouteMap: UIViewRepresentable {
    var branches: [Branch]

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let map = makeBaseMap(delegate: context.coordinator)
        container.addSubview(map)
        addZoomStrip(to: container, map: map)
        context.coordinator.map = map
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let map = context.coordinator.map else { return }
        context.coordinator.update(branches.map(\.path).filter { $0.count > 1 }, on: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var map: MLNMapView?
        private var source: MLNShapeSource?
        private var paths: [[Coordinate]] = []
        private var didFit = false

        func update(_ paths: [[Coordinate]], on map: MLNMapView) {
            if paths != self.paths { didFit = false }
            self.paths = paths
            apply(on: map)
        }

        private func apply(on map: MLNMapView) {
            guard let source else { return }
            source.shape = MLNShapeCollectionFeature(shapes: paths.map { path in
                var coordinates = path.map(\.location)
                return MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
            })
            var coordinates = paths.flatMap { $0 }.map(\.location)
            guard !didFit, !coordinates.isEmpty, map.bounds.width > 0 else { return }
            didFit = true
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
            apply(on: mapView)
        }
    }
}
