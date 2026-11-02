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
    return map
}
