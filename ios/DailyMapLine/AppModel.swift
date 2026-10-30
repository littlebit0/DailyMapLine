import CoreLocation
import DailyMapLineCore
import Foundation

enum RecordingStatus {
    case off, denied, moving, stopped, noSignal

    var text: String {
        switch self {
        case .off: "위치 기록이 꺼져 있어요."
        case .denied: "위치 권한을 확인해 주세요. 기존 기록은 볼 수 있어요."
        case .moving: "이동을 기록하고 있어요."
        case .stopped: "머무는 동안 노드 기록을 쉬고 있어요."
        case .noSignal: "현재 위치를 받지 못하고 있어요."
        }
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status = RecordingStatus.off
    @Published private(set) var branches: [Branch] = []
    @Published private(set) var dates: Set<String> = []
    @Published private(set) var hasUnconnected = false
    @Published var errorMessage: String?
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            if enabled { start() } else { stop() }
        }
    }

    private enum Keys {
        static let enabled = "recordingEnabled"
        static let pendingGap = "pendingGap"
    }

    /// Experimental: a silence this long is treated as a reception gap and is not routed across.
    private static let gapSeconds: TimeInterval = 600

    let store: RecordStore?
    private let router: RoadRouter?
    private let manager = CLLocationManager()
    private var policy = RecordingPolicy()
    private var lastFix: (location: CLLocation, time: Date)?

    override init() {
        enabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        router = Bundle.main.url(forResource: "roads", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? RoadRouter(json: $0) }
        do {
            store = try RecordStore(path: try Self.databaseURL().path)
        } catch {
            store = nil
            errorMessage = "기록 저장소를 열지 못했어요. \(error)"
        }
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.pausesLocationUpdatesAutomatically = false
        seedForDebug()
        reload()
        if enabled {
            // A new process cannot know what happened since the last fix.
            UserDefaults.standard.set(true, forKey: Keys.pendingGap)
            start()
        }
    }

    private static func databaseURL() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var url = folder.appendingPathComponent("records.sqlite")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        // OS auto-backup policy is undecided, so location history stays off iCloud until it is chosen.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    private func seedForDebug() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-seedSample"), let store, (try? store.lastNode()) == nil else { return }
        let sample = [(126.9774, 37.5664), (126.9770, 37.5701), (126.9831, 37.5703), (126.9826, 37.5662), (126.9774, 37.5664)]
        for point in sample {
            try? store.record(Coordinate(lon: point.0, lat: point.1), date: "2026-10-31", router: router)
        }
        #endif
    }

    func reload() {
        guard let store else { return }
        do {
            let all = try store.allBranches()
            branches = all
            hasUnconnected = all.contains { $0.state == .dataMissing || $0.state == .failed }
            dates = Set(try store.recordedDates())
        } catch {
            errorMessage = "기록을 읽지 못했어요. \(error)"
        }
    }

    private func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
            if status != .stopped { status = .moving }
        default:
            status = .denied
        }
    }

    private func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        UserDefaults.standard.set(true, forKey: Keys.pendingGap)
        policy = RecordingPolicy()
        lastFix = nil
        status = .off
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in if self.enabled { self.start() } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in if self.enabled { self.status = .noSignal } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in locations.forEach(self.handle) }
    }

    private func handle(_ location: CLLocation) {
        guard enabled, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else { return }
        var speed = max(location.speed, 0) * 3.6
        if location.speed < 0, let last = lastFix {
            let seconds = location.timestamp.timeIntervalSince(last.time)
            if seconds > 0 { speed = location.distance(from: last.location) / seconds * 3.6 }
        }
        let silent = lastFix.map { location.timestamp.timeIntervalSince($0.time) >= Self.gapSeconds } ?? false
        if silent { UserDefaults.standard.set(true, forKey: Keys.pendingGap) }
        lastFix = (location, location.timestamp)
        let fix = Coordinate(lon: location.coordinate.longitude, lat: location.coordinate.latitude)
        let record = policy.shouldRecord(fix, speedKmh: speed, at: location.timestamp)
        status = policy.isStopped ? .stopped : .moving
        guard record, let store else { return }
        do {
            let afterGap = UserDefaults.standard.bool(forKey: Keys.pendingGap)
            try store.record(fix, date: Self.localDate(location.timestamp), router: router, afterGap: afterGap)
            UserDefaults.standard.set(false, forKey: Keys.pendingGap)
            reload()
        } catch {
            errorMessage = "위치를 저장하지 못했어요. \(error)"
        }
    }

    /// Returns false when nothing was deleted; existing records stay intact in that case.
    func deleteDay(_ date: String) -> Bool {
        guard let store else { return false }
        do {
            // Without its last node the next fix must not be routed from an older position.
            if let last = try store.lastNode(), try store.nodes(date: date).contains(last) {
                UserDefaults.standard.set(true, forKey: Keys.pendingGap)
            }
            try store.deleteDay(date: date)
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("DailyMapLine-\(date).mp4"))
            reload()
            return true
        } catch {
            errorMessage = "기록을 삭제하지 못했어요. 기존 기록은 그대로예요. \(error)"
            return false
        }
    }

    static func localDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
