import CoreLocation
import DailyMapLineCore
import Foundation

enum RecordingStatus {
    case off, waitingPermission, denied, moving, stopped, noSignal, noRoad

    var text: String {
        switch self {
        case .off: "위치 기록이 꺼져 있어요."
        case .waitingPermission: "위치 권한을 허용하면 기록을 시작해요."
        case .denied: "위치 권한을 확인해 주세요. 기존 기록은 볼 수 있어요."
        case .moving: "이동을 기록하고 있어요."
        case .stopped: "머무는 동안 노드 기록을 쉬고 있어요."
        case .noSignal: "현재 위치를 받지 못하고 있어요."
        case .noRoad: "길이 없는 곳이라 기록하지 않고 있어요."
        }
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status = RecordingStatus.off
    @Published private(set) var branches: [Branch] = []
    /// Road path from the last node to the current position, shown until the next node is saved. Never stored.
    @Published private(set) var livePath: [Coordinate] = []
    @Published private(set) var dates: Set<String> = []
    @Published private(set) var hasUnconnected = false
    /// Only "Always" lets iOS relaunch the app for recording after it is fully closed.
    @Published private(set) var isWhenInUseOnly = false
    @Published private(set) var locationAllowed = false
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
    private let router: (any RoadRouting)?
    private let manager = CLLocationManager()
    private var policy = RecordingPolicy()
    private var lastFix: (location: CLLocation, time: Date)?
    /// Keeps background updates alive while recording.
    private var backgroundSession: CLBackgroundActivitySession?
    private static let wakeRegion = "wake"

    override init() {
        enabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        // Without the tiles every branch is kept as dataMissing until they are available.
        router = Bundle.main.url(forResource: "valhalla_tiles", withExtension: "tar").flatMap(ValhallaRouter.init(tiles:))
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
        updateLocationAllowed()
        seedForDebug()
        if let store, let router {
            _ = try? store.recalculateUnconnected(router: router)
        }
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
        let sample = [
            (126.9774, 37.5664, "2026-10-31"), (126.9770, 37.5701, "2026-10-31"), (126.9831, 37.5703, "2026-10-31"),
            (126.9826, 37.5662, "2026-10-31"), (126.9774, 37.5664, "2026-10-31"), (126.9831, 37.5703, "2026-11-01"),
        ]
        for point in sample {
            try? store.record(Coordinate(lon: point.0, lat: point.1), date: point.2, router: router)
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

    private func updateLocationAllowed() {
        locationAllowed = [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus)
    }

    /// For showing the current position only. Nothing is recorded unless recording is on.
    func askForCurrentLocation() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if !locationAllowed {
            errorMessage = "현재 위치를 보려면 설정 앱에서 위치 권한을 허용해 주세요."
        }
    }

    private func start() {
        isWhenInUseOnly = manager.authorizationStatus == .authorizedWhenInUse
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .waitingPermission
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
            if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
            if status != .stopped { status = .moving }
        default:
            status = .denied
        }
    }

    private func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.monitoredRegions.forEach(manager.stopMonitoring)
        backgroundSession?.invalidate()
        backgroundSession = nil
        UserDefaults.standard.set(true, forKey: Keys.pendingGap)
        policy = RecordingPolicy()
        lastFix = nil
        isWhenInUseOnly = false
        status = .off
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.updateLocationAllowed()
            if self.enabled { self.start() }
        }
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
        armWakeRegion(around: location)
        let fix = Coordinate(lon: location.coordinate.longitude, lat: location.coordinate.latitude)
        if router?.hasNoRoad(near: fix) == true {
            // Off-road positions are not stored, so the next node must not connect across them.
            UserDefaults.standard.set(true, forKey: Keys.pendingGap)
            status = .noRoad
            return
        }
        let record = policy.shouldRecord(fix, speedKmh: speed, at: location.timestamp)
        status = policy.isStopped ? .stopped : .moving
        updateLivePath(to: fix, speedKmh: speed)
        guard record, let store else { return }
        do {
            let afterGap = UserDefaults.standard.bool(forKey: Keys.pendingGap)
            try store.record(fix, date: Self.localDate(location.timestamp), router: router, speedKmh: speed, afterGap: afterGap)
            UserDefaults.standard.set(false, forKey: Keys.pendingGap)
            livePath = []
            reload()
        } catch {
            errorMessage = "위치를 저장하지 못했어요. \(error)"
        }
    }

    /// After the app is swiped away, leaving this circle relaunches it within about 100 m,
    /// much sooner than significant-change monitoring (about 500 m). Needs "Always" permission.
    private func armWakeRegion(around location: CLLocation) {
        let current = manager.monitoredRegions.first { $0.identifier == Self.wakeRegion } as? CLCircularRegion
        if let current, current.contains(location.coordinate),
           CLLocation(latitude: current.center.latitude, longitude: current.center.longitude).distance(from: location) < 50 { return }
        let region = CLCircularRegion(center: location.coordinate, radius: 100, identifier: Self.wakeRegion)
        region.notifyOnEntry = false
        manager.startMonitoring(for: region)
    }

    /// Follows the same road-only rule as branches, and never bridges a gap the next node will not connect.
    private func updateLivePath(to fix: Coordinate, speedKmh: Double) {
        guard !UserDefaults.standard.bool(forKey: Keys.pendingGap), let last = try? store?.lastNode(), let router else {
            livePath = []
            return
        }
        // Routing every fix is wasted work when the position barely moved.
        if let end = livePath.last, distanceMeters(end, fix) < 10 { return }
        if case .road(let path) = router.route(from: last.coordinate, to: fix, speedKmh: speedKmh) { livePath = path }
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
            // Any generated video may cover this date, so none of them outlive the deletion.
            let temporary = FileManager.default.temporaryDirectory
            for file in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [] where file.hasPrefix("DailyMapLine-") {
                try? FileManager.default.removeItem(at: temporary.appendingPathComponent(file))
            }
            reload()
            return true
        } catch {
            errorMessage = "기록을 삭제하지 못했어요. 기존 기록은 그대로예요. \(error)"
            return false
        }
    }

    /// Returns false when the restore failed; existing records stay intact in that case.
    func restoreBackup(_ data: Data) -> Bool {
        guard let store else { return false }
        do {
            // The restored last node is unrelated to the next position.
            UserDefaults.standard.set(true, forKey: Keys.pendingGap)
            try store.restoreBackup(data)
            reload()
            return true
        } catch {
            errorMessage = "백업을 복원하지 못했어요. 기존 기록은 그대로예요. \(error)"
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
