import DailyMapLineCore
import MapLibre
import SwiftUI

/// Covers everything, then clears a 100 m wide stroke along each branch (50 m per side).
/// Stroking real paths keeps loop interiors covered unless buffers actually overlap there.
final class FogOverlay: UIView {
    weak var map: MLNMapView?
    var paths: [[Coordinate]] = [] { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = true
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
        context.setBlendMode(.normal)
        drawUserLocation(context, map)
    }

    /// Drawn here because the map's own marker sits under this overlay and would be dimmed by the fog.
    private func drawUserLocation(_ context: CGContext, _ map: MLNMapView) {
        guard map.showsUserLocation, let user = map.userLocation, let location = user.location else { return }
        let point = map.convert(location.coordinate, toPointTo: self)
        let blue = UIColor(red: 0.141, green: 0.490, blue: 0.867, alpha: 1)
        if let direction = Self.direction(user.heading, location) {
            // Compass degrees run clockwise from north; screen angles run clockwise from east.
            let center = CGFloat((direction - map.direction - 90) * .pi / 180)
            context.setFillColor(blue.withAlphaComponent(0.35).cgColor)
            context.move(to: point)
            context.addArc(center: point, radius: 36, startAngle: center - .pi / 5, endAngle: center + .pi / 5, clockwise: false)
            context.closePath()
            context.fillPath()
        }
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
        context.setFillColor(blue.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
        drawSpeed(location, below: point)
    }

    private func drawSpeed(_ location: CLLocation, below point: CGPoint) {
        // A negative speed means iOS has no valid reading, which is not the same as standing still.
        let text = location.speed >= 0 ? "\(Int((location.speed * 3.6).rounded())) km/h" : "-- km/h"
        accessibilityLabel = "현재 속도 \(text)"
        let label = NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: UIColor(red: 0.145, green: 0.243, blue: 0.329, alpha: 1),
        ])
        let size = label.size()
        let origin = CGPoint(x: point.x - size.width / 2, y: point.y + 14)
        UIColor.white.withAlphaComponent(0.92).setFill()
        UIBezierPath(roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -2), cornerRadius: 6).fill()
        label.draw(at: origin)
    }

    /// Compass when available, otherwise the direction of travel.
    private static func direction(_ heading: CLHeading?, _ location: CLLocation) -> CLLocationDirection? {
        if let heading, heading.headingAccuracy >= 0 {
            return heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        }
        return location.course >= 0 ? location.course : nil
    }
}

/// The map screen: reveals visited areas and shows the current position. It never draws route lines.
struct VisitedMap: UIViewRepresentable {
    var branches: [Branch]
    var showsUserLocation: Bool
    var recenterRequest: Int

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let map = makeBaseMap(delegate: context.coordinator)
        container.addSubview(map)
        context.coordinator.map = map
        let overlay = FogOverlay()
        overlay.map = map
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(overlay)
        context.coordinator.overlay = overlay
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.overlay?.paths = branches.map(\.path).filter { $0.count > 1 }
        context.coordinator.updateUserLocation(showsUserLocation, recenterRequest: recenterRequest)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var map: MLNMapView?
        weak var overlay: FogOverlay?
        private var handledRecenter = 0

        func updateUserLocation(_ shows: Bool, recenterRequest: Int) {
            guard let map else { return }
            if map.showsUserLocation != shows {
                map.showsUserLocation = shows
                map.showsUserHeadingIndicator = shows
            }
            guard shows, recenterRequest != handledRecenter else { return }
            handledRecenter = recenterRequest
            map.setUserTrackingMode(.follow, animated: true, completionHandler: nil)
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            annotation is MLNUserLocation ? MLNUserLocationAnnotationView() : nil
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) { overlay?.setNeedsDisplay() }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) { overlay?.setNeedsDisplay() }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) { overlay?.setNeedsDisplay() }
    }
}
