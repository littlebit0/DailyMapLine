import AVKit
import DailyMapLineCore
import Photos
import SwiftUI
import UniformTypeIdentifiers

@main
struct DailyMapLineApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup { MapScreen().environmentObject(delegate.model) }
    }
}

/// iOS relaunches a closed app in the background for location events without creating any scene,
/// so the model is created at launch here instead of by the first view.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor lazy var model = AppModel()

    @MainActor func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = model
        return true
    }
}

struct MapScreen: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("didShowIntro") private var didShowIntro = false
    @State private var recenterRequest = 0
    @State private var northRequest = 0
    @State private var wantsRecenter = false

    var body: some View {
        NavigationStack {
            VisitedMap(branches: model.branches, livePath: model.livePath, showsUserLocation: model.locationAllowed, recenterRequest: recenterRequest, northRequest: northRequest)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottomLeading) { Attribution() }
                .overlay(alignment: .bottomTrailing) {
                    VStack(spacing: 12) {
                    Button { northRequest += 1 } label: {
                        Image(systemName: "location.north.line.fill")
                            .frame(width: 48, height: 48)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("지도 북쪽 위로")
                    Button {
                        if model.locationAllowed {
                            recenterRequest += 1
                        } else {
                            wantsRecenter = true
                            model.askForCurrentLocation()
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .frame(width: 48, height: 48)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("현위치")
                    }
                    .padding(16)
                }
                .onChange(of: model.locationAllowed) { _, allowed in
                    if allowed, wantsRecenter {
                        wantsRecenter = false
                        recenterRequest += 1
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { StatusBanner() }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink("영상 만들기") { RecordVideoScreen() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { SettingsScreen() } label: { Label("설정", systemImage: "gearshape") }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: Binding(get: { !didShowIntro }, set: { if !$0 { didShowIntro = true } })) { IntroSheet() }
        .alert("오류", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct Attribution: View {
    var body: some View {
        Link("Protomaps © OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.white.opacity(0.9))
            .padding(8)
    }
}

private struct StatusBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.status.text)
            if model.hasUnconnected { Text("일부 구간의 길을 연결하지 못했어요. 노드는 보관했어요.") }
            if model.isWhenInUseOnly { AlwaysPermissionNotice() }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial)
    }
}

private struct AlwaysPermissionNotice: View {
    var body: some View {
        Text("앱을 완전히 닫으면 기록이 멈출 수 있어요. 위치 권한을 '항상'으로 바꿔 주세요.")
        if let url = URL(string: UIApplication.openSettingsURLString) {
            Link("설정 앱에서 권한 열기", destination: url)
        }
    }
}

private struct IntroSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("이동을 기록해 기록영상으로 만들어요").font(.title2.bold())
            Text("위치 기록을 켜면 앱을 닫아 둔 동안에도 이동을 기록하려고 시도해요. 운영체제 상황에 따라 기록 간격은 달라질 수 있어요.")
            Text("기록은 이 기기에만 저장하고 서버로 보내지 않아요. 기록을 끄면 새 위치를 저장하지 않아요.")
            Spacer()
            Button("위치 기록 켜기") {
                model.enabled = true
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            Button("지도만 보기") { dismiss() }
                .frame(maxWidth: .infinity)
        }
        .padding(24)
    }
}

private struct BackupDocument: FileDocument {
    static let readableContentTypes = [UTType.data]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var exportDocument: BackupDocument?
    @State private var isImporting = false
    @State private var pending: (data: Data, summary: BackupSummary)?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("위치 기록", isOn: $model.enabled)
                Text(model.status.text).font(.footnote).foregroundStyle(.secondary)
                if model.status == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("설정 앱에서 권한 열기", destination: url)
                }
                if model.isWhenInUseOnly { AlwaysPermissionNotice().font(.footnote) }
            }
            Section("백업") {
                Button("기록 내보내기") { export() }
                Button("기록 가져오기") { isImporting = true }
                Text("백업 파일은 암호화되지 않아요. 파일을 가진 사람은 이동 기록을 볼 수 있으니 안전한 곳에 보관해 주세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let message { Text(message).font(.footnote) }
            }
        }
        .navigationTitle("설정")
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .data,
            defaultFilename: "DailyMapLine-\(AppModel.localDate(Date())).dmlbackup"
        ) { result in
            switch result {
            case .success: message = "기록을 내보냈어요."
            case .failure(let error) where (error as? CocoaError)?.code == .userCancelled: message = nil
            case .failure: message = "내보내지 못했어요. 기록은 그대로예요."
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { inspect(url) }
        }
        .alert("현재 기록을 모두 교체할까요?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { backup in
            Button("교체", role: .destructive) {
                if model.restoreBackup(backup.data) { message = "백업을 복원했어요." }
            }
            Button("취소", role: .cancel) {}
        } message: { backup in
            let current = (try? model.store?.nodeCount()) ?? 0
            Text("현재 노드 \(current)개를 지우고, 백업의 \(backup.summary.dates.count)일치 기록(노드 \(backup.summary.nodeCount)개, 브랜치 \(backup.summary.branchCount)개)으로 바꿔요. 되돌릴 수 없어요.")
        }
    }

    private func export() {
        do {
            guard let data = try model.store?.exportBackup() else { return }
            exportDocument = BackupDocument(data: data)
        } catch {
            message = "내보내지 못했어요. 기록은 그대로예요."
        }
    }

    private func inspect(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            pending = (data, try RecordStore.inspectBackup(data))
            message = nil
        } catch let error as StoreError {
            message = error.description
        } catch {
            message = "파일을 읽지 못했어요."
        }
    }
}

/// One month. Only recorded dates can be picked.
private struct MonthPicker: View {
    let title: String
    let recorded: Set<String>
    @Binding var selection: String?
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start

    private var cells: [Date?] {
        let calendar = Calendar.current
        let leading = calendar.component(.weekday, from: month) - 1
        let count = calendar.range(of: .day, in: .month, for: month)!.count
        return Array(repeating: nil, count: leading) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: month) }
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.subheadline.bold())
            Text(selection ?? "날짜 선택").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                    .accessibilityLabel("\(title) 이전 달")
                Spacer(minLength: 0)
                Text(month, format: .dateTime.year().month()).font(.caption.bold())
                Spacer(minLength: 0)
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
                    .accessibilityLabel("\(title) 다음 달")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) {
                    Text($0.element).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(height: 44) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let date = AppModel.localDate(day)
        let number = Text("\(Calendar.current.component(.day, from: day))")
            .font(.caption)
            .frame(maxWidth: .infinity, minHeight: 44)
        if recorded.contains(date) {
            Button { selection = date } label: {
                number
                    .foregroundStyle(selection == date ? Color.white : Color.accentColor)
                    .background(selection == date ? Color.accentColor : Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            }
            .accessibilityLabel("\(title) \(date) 기록 있음")
            .accessibilityAddTraits(selection == date ? .isSelected : [])
        } else {
            number.foregroundStyle(.tertiary)
        }
    }

    private func shift(_ value: Int) {
        month = Calendar.current.date(byAdding: .month, value: value, to: month) ?? month
    }
}

struct RecordVideoScreen: View {
    private enum Phase {
        case setup, rendering(Double), preview(URL, AVPlayer), failed(String)
    }

    @EnvironmentObject private var model: AppModel
    @State private var start: String?
    @State private var end: String?
    @State private var phase = Phase.setup
    @State private var saveMessage: String?
    @State private var deletion: DeletionPreview?

    private var rangeIsValid: Bool {
        guard let start, let end else { return false }
        return start <= end
    }

    private var branches: [Branch] {
        guard rangeIsValid, let start, let end else { return [] }
        return (try? model.store?.branches(from: start, to: end)) ?? []
    }

    private var label: String {
        guard let start, let end else { return "" }
        return start == end ? start : "\(start) – \(end)"
    }

    /// Deletion stays per date, so it is offered only when one date is selected.
    private var singleDate: String? {
        guard let start, end == nil || end == start else { return nil }
        return start
    }

    var body: some View {
        Group {
            switch phase {
            case .setup:
                setup
            case .rendering(let progress):
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView(value: progress)
                    Text("휴대폰에서 기록영상을 만들고 있어요.")
                    Spacer()
                }
                .padding()
            case .preview(let url, let player):
                preview(url, player)
            case .failed(let message):
                VStack(spacing: 16) {
                    Spacer()
                    Text(message)
                    Button("다시 시도") { render() }.buttonStyle(.borderedProminent)
                    Button("날짜 다시 고르기") { phase = .setup }
                    Spacer()
                }
                .padding()
            }
        }
        .navigationTitle("기록영상")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if case .setup = phase, let singleDate {
                    Button(role: .destructive) {
                        do {
                            deletion = try model.store?.deletionPreview(date: singleDate)
                        } catch {
                            model.errorMessage = "삭제 범위를 확인하지 못했어요. \(error)"
                        }
                    } label: {
                        Label("이 날짜 기록 삭제", systemImage: "trash")
                    }
                }
            }
        }
        .alert("\(singleDate ?? "") 기록을 삭제할까요?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { _ in
            Button("삭제", role: .destructive) {
                if let singleDate, model.deleteDay(singleDate) {
                    start = nil
                    end = nil
                }
            }
            Button("취소", role: .cancel) {}
        } message: { deletion in
            Text(deletionMessage(deletion))
        }
    }

    private var setup: some View {
        let branches = branches
        let timeline = VideoTimeline(branches: branches)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                MonthPicker(title: "시작", recorded: model.dates, selection: $start)
                Divider()
                MonthPicker(title: "종료", recorded: model.dates, selection: $end)
                if model.dates.isEmpty {
                    Text("아직 기록이 없어요.").font(.footnote)
                } else if start != nil, end != nil, !rangeIsValid {
                    Text("종료 날짜는 시작 날짜와 같거나 뒤여야 해요.").font(.footnote)
                } else if rangeIsValid, timeline.lengthMeters <= 0 {
                    Text("기록영상을 만들 수 있는 이동 경로가 없어요.").font(.footnote)
                }
                if timeline.lengthMeters > 0 {
                    RecordRouteMap(branches: branches)
                        .frame(height: 220)
                        .overlay(alignment: .bottomLeading) { Attribution() }
                    Text(String(format: "길이 %.2f km · 기록영상 %.0f초", timeline.lengthMeters / 1000, timeline.durationSeconds))
                }
                Button("기록영상 만들기") { render() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(timeline.lengthMeters <= 0)
            }
            .padding()
        }
    }

    private func preview(_ url: URL, _ player: AVPlayer) -> some View {
        VStack(spacing: 16) {
            VideoPlayer(player: player).aspectRatio(9 / 16, contentMode: .fit)
            HStack {
                Button("영상 다운로드") { save(url) }.buttonStyle(.borderedProminent)
                ShareLink("공유", item: url).buttonStyle(.bordered)
            }
            if let saveMessage { Text(saveMessage).font(.footnote) }
            Button("날짜 다시 고르기") {
                player.pause()
                saveMessage = nil
                phase = .setup
            }
        }
        .padding()
    }

    private func deletionMessage(_ preview: DeletionPreview) -> String {
        var lines = ["노드 \(preview.deletedNodes)개와 브랜치 \(preview.deletedBranches)개를 삭제해요. 되돌릴 수 없어요."]
        if preview.retainedNodes > 0 {
            let dates = preview.referencedBy.joined(separator: ", ")
            lines.append("이 날의 위치 \(preview.retainedNodes)곳은 \(dates) 기록영상의 시작점이라 남아요. \(dates) 기록을 삭제하면 함께 지워져요.")
        }
        lines.append("사진에 저장했거나 공유한 기록영상은 지워지지 않아요.")
        return lines.joined(separator: "\n\n")
    }

    private func render() {
        let timeline = VideoTimeline(branches: branches)
        let label = label
        phase = .rendering(0)
        Task {
            do {
                let url = try await VideoRenderer.render(date: label, timeline: timeline) { phase = .rendering($0) }
                let player = AVPlayer(url: url)
                player.play()
                phase = .preview(url, player)
            } catch {
                phase = .failed("기록영상을 만들지 못했어요. 원본 기록은 그대로예요. \(error.localizedDescription)")
            }
        }
    }

    private func save(_ url: URL) {
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                saveMessage = "사진 보관함에 저장했어요."
            } catch {
                saveMessage = "기록영상을 저장하지 못했어요. 저장 공간과 권한을 확인해 주세요."
            }
        }
    }
}
