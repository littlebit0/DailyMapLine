import DailyMapLineCore
import MapLibre
import SwiftUI

enum MapStyle {
    /// Local style over the bundled Protomaps Korea extract, so the map makes no network requests.
    /// shortcut: Korea only, other regions stay empty until world data delivery is decided.
    static let url: URL? = {
        let bundle = Bundle.main
        guard let tiles = bundle.url(forResource: "korea", withExtension: "pmtiles"),
              let glyphs = bundle.url(forResource: "Glyphs", withExtension: "bundle"),
              let sprite = bundle.url(forResource: "light", withExtension: "png")?.deletingPathExtension(),
              let layerFile = bundle.url(forResource: "basemap-layers", withExtension: "json"),
              let layerData = try? Data(contentsOf: layerFile),
              let layers = try? JSONSerialization.jsonObject(with: layerData) else { return nil }
        let style: [String: Any] = [
            "version": 8,
            "glyphs": glyphs.absoluteString + "{fontstack}/{range}.pbf",
            "sprite": sprite.absoluteString,
            "sources": ["protomaps": ["type": "vector", "url": "pmtiles://" + tiles.absoluteString, "attribution": "Protomaps © OpenStreetMap"]],
            "layers": layers,
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

/// Shared setup for every interactive map. Screen-specific drawing lives in each screen's own map type.
func makeBaseMap(delegate: MLNMapViewDelegate) -> MLNMapView {
    let map = MLNMapView(frame: .zero, styleURL: MapStyle.url)
    map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    map.delegate = delegate
    map.logoView.isHidden = true
    map.attributionButton.isHidden = true
    map.compassView.isHidden = true
    map.setCenter(MapStyle.center, zoomLevel: 14.5, animated: false)
    // Zoom moves to the left-edge strip, so double tap and double-tap-and-drag zoom are turned off.
    for gesture in map.gestureRecognizers ?? [] {
        if let tap = gesture as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2, tap.numberOfTouchesRequired == 1 { tap.isEnabled = false }
        if let press = gesture as? UILongPressGestureRecognizer, press.numberOfTapsRequired == 1 { press.isEnabled = false }
    }
    return map
}

/// The strip sits next to the map, not inside it, so the map's own gestures never see its touches.
func addZoomStrip(to container: UIView, map: MLNMapView) {
    let strip = ZoomStrip(map: map)
    strip.frame = CGRect(x: 0, y: 0, width: ZoomStrip.width, height: container.bounds.height)
    strip.autoresizingMask = [.flexibleHeight, .flexibleRightMargin]
    container.addSubview(strip)
}

/// Vertical swipe along the left edge zooms: up zooms in, down zooms out. Pinch still works.
/// While dragging, the handle grows into a knob that follows the finger and shows the zoom direction.
final class ZoomStrip: UIView {
    static let width: CGFloat = 44
    /// Points of vertical travel for one zoom level.
    private static let pointsPerZoomLevel: CGFloat = 120
    private static let idleSize = CGSize(width: 4, height: 64)
    private static let activeSize = CGSize(width: 32, height: 48)

    private weak var map: MLNMapView?
    private let knob = UIView()
    private let sign = UILabel()
    private var startZoom = 0.0
    private var startY: CGFloat = 0
    private var isDragging = false

    init(map: MLNMapView) {
        self.map = map
        super.init(frame: .zero)
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.85)
        knob.layer.cornerRadius = Self.idleSize.width / 2
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0
        knob.layer.shadowRadius = 4
        knob.layer.shadowOffset = CGSize(width: 0, height: 1)
        sign.font = .systemFont(ofSize: 20, weight: .bold)
        sign.textColor = UIColor(red: 0.141, green: 0.490, blue: 0.867, alpha: 1)
        sign.textAlignment = .center
        sign.alpha = 0
        knob.addSubview(sign)
        addSubview(knob)
        isAccessibilityElement = true
        accessibilityLabel = "지도 확대 축소"
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !isDragging { place(at: bounds.midY, active: false) }
    }

    private func place(at y: CGFloat, active: Bool) {
        let size = active ? Self.activeSize : Self.idleSize
        knob.bounds.size = size
        knob.center = CGPoint(x: active ? 4 + size.width / 2 : 8, y: min(max(y, size.height / 2), bounds.height - size.height / 2))
        knob.layer.cornerRadius = min(size.width, size.height) / 2
        knob.layer.shadowOpacity = active ? 0.25 : 0
        knob.backgroundColor = UIColor.white.withAlphaComponent(active ? 1 : 0.85)
        sign.frame = knob.bounds
        sign.alpha = active ? 1 : 0
    }

    /// Springs between the idle bar and the knob, or jumps when Reduce Motion is on.
    private func animate(_ changes: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled { return changes() }
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5, options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
    }

    // Raw touches respond on the first contact; a pan recognizer would wait for movement first.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let map, let y = touches.first?.location(in: self).y else { return }
        isDragging = true
        startY = y
        startZoom = map.zoomLevel
        sign.text = "+"
        animate { self.place(at: y, active: true) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let map, let y = touches.first?.location(in: self).y else { return }
        sign.text = y <= startY ? "+" : "−"
        // Only the position follows the finger, so it never fights the size spring.
        knob.center.y = min(max(y, knob.bounds.height / 2), bounds.height - knob.bounds.height / 2)
        map.setZoomLevel(startZoom - Double((y - startY) / Self.pointsPerZoomLevel), animated: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release() }

    private func release() {
        isDragging = false
        animate { self.place(at: self.bounds.midY, active: false) }
    }

    override func accessibilityIncrement() { map.map { $0.setZoomLevel($0.zoomLevel + 1, animated: true) } }
    override func accessibilityDecrement() { map.map { $0.setZoomLevel($0.zoomLevel - 1, animated: true) } }
}
