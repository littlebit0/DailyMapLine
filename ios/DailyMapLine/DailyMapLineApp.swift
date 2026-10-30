import AVKit
import DailyMapLineCore
import Photos
import SwiftUI

@main
struct DailyMapLineApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup { MainView().environmentObject(model) }
    }
}

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("didShowIntro") private var didShowIntro = false

    var body: some View {
        NavigationStack {
            RouteMap(branches: model.branches, fog: true)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottomLeading) { Attribution() }
                .safeAreaInset(edge: .top, spacing: 0) { StatusBanner() }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink { CalendarScreen() } label: { Label("월 달력", systemImage: "calendar") }
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
        Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
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
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial)
    }
}

private struct IntroSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("이동을 기록해 영상으로 만들어요").font(.title2.bold())
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

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("위치 기록", isOn: $model.enabled)
                Text(model.status.text).font(.footnote).foregroundStyle(.secondary)
                if model.status == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("설정 앱에서 권한 열기", destination: url)
                }
            }
        }
        .navigationTitle("설정")
    }
}

struct CalendarScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start

    private var cells: [Date?] {
        let calendar = Calendar.current
        let leading = calendar.component(.weekday, from: month) - 1
        let count = calendar.range(of: .day, in: .month, for: month)!.count
        return Array(repeating: nil, count: leading) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: month) }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("이전 달")
                Spacer()
                Text(month, format: .dateTime.year().month()).font(.headline)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("다음 달")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) { Text($0.element).font(.caption) }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(height: 44) }
                }
            }
            Spacer()
        }
        .padding()
        .navigationTitle("월 달력")
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let date = AppModel.localDate(day)
        let number = Text("\(Calendar.current.component(.day, from: day))").frame(maxWidth: .infinity, minHeight: 44)
        if model.dates.contains(date) {
            NavigationLink { DayScreen(date: date) } label: {
                number.background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("\(date) 기록 있음")
        } else {
            number.foregroundStyle(.secondary)
        }
    }

    private func shift(_ value: Int) {
        month = Calendar.current.date(byAdding: .month, value: value, to: month) ?? month
    }
}

struct DayScreen: View {
    @EnvironmentObject private var model: AppModel
    let date: String
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [Branch] = []
    @State private var preview: DeletionPreview?

    private var connected: Bool { branches.contains { $0.path.count > 1 } }

    private func deletionMessage(_ preview: DeletionPreview) -> String {
        var lines = ["노드 \(preview.deletedNodes)개와 브랜치 \(preview.deletedBranches)개를 삭제해요. 되돌릴 수 없어요."]
        if preview.retainedNodes > 0 {
            let dates = preview.referencedBy.joined(separator: ", ")
            lines.append("이 날의 위치 \(preview.retainedNodes)곳은 \(dates) 영상의 시작점이라 남아요. \(dates) 기록을 삭제하면 함께 지워져요.")
        }
        lines.append("사진에 저장했거나 공유한 영상은 지워지지 않아요.")
        return lines.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            RouteMap(branches: branches, fog: false, fitsRoute: true)
                .overlay(alignment: .bottomLeading) { Attribution() }
            Group {
                if connected {
                    NavigationLink("영상 만들기") { VideoScreen(date: date, branches: branches) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("영상을 만들 수 있는 이동 경로가 없어요.").font(.footnote)
                }
            }
            .padding()
        }
        .navigationTitle(date)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    do {
                        preview = try model.store?.deletionPreview(date: date)
                    } catch {
                        model.errorMessage = "삭제 범위를 확인하지 못했어요. \(error)"
                    }
                } label: {
                    Label("이 날짜 기록 삭제", systemImage: "trash")
                }
            }
        }
        .alert("\(date) 기록을 삭제할까요?", isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } }), presenting: preview) { _ in
            Button("삭제", role: .destructive) {
                if model.deleteDay(date) { dismiss() }
            }
            Button("취소", role: .cancel) {}
        } message: { preview in
            Text(deletionMessage(preview))
        }
        .task { branches = (try? model.store?.branches(date: date)) ?? [] }
    }
}

struct VideoScreen: View {
    private enum Phase {
        case setup, rendering(Double), done(URL), failed(String)
    }

    let date: String
    let branches: [Branch]
    @State private var phase = Phase.setup
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0
    @State private var saveMessage: String?

    private var total: Double { VideoTimeline(branches: branches).lengthMeters }
    private var timeline: VideoTimeline { VideoTimeline(branches: branches, trimStartMeters: trimStart, trimEndMeters: trimEnd) }

    var body: some View {
        VStack(spacing: 16) {
            switch phase {
            case .setup:
                setup
            case .rendering(let progress):
                Spacer()
                ProgressView(value: progress)
                Text("휴대폰에서 영상을 만들고 있어요.")
                Spacer()
            case .done(let url):
                VideoPlayer(player: AVPlayer(url: url)).aspectRatio(9 / 16, contentMode: .fit)
                HStack {
                    Button("사진에 저장") { save(url) }.buttonStyle(.borderedProminent)
                    ShareLink("공유", item: url).buttonStyle(.bordered)
                }
                if let saveMessage { Text(saveMessage).font(.footnote) }
            case .failed(let message):
                Spacer()
                Text(message)
                Button("다시 시도") { render() }.buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .padding()
        .navigationTitle("영상")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(date).font(.headline)
            Text(String(format: "길이 %.2f km · 영상 약 %.1f초", timeline.lengthMeters / 1000, timeline.durationSeconds))
            Text(String(format: "시작에서 %.0f m 제외", trimStart))
            Slider(value: $trimStart, in: 0...max(1, total), step: 50)
                .accessibilityLabel("시작 구간 제외")
            Text(String(format: "끝에서 %.0f m 제외", trimEnd))
            Slider(value: $trimEnd, in: 0...max(1, total), step: 50)
                .accessibilityLabel("끝 구간 제외")
            Text("제외해도 원본 기록은 유지돼요.").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("영상 만들기") { render() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(timeline.lengthMeters <= 0)
        }
    }

    private func render() {
        phase = .rendering(0)
        Task {
            do {
                let url = try await VideoRenderer.render(date: date, timeline: timeline) { phase = .rendering($0) }
                phase = .done(url)
            } catch {
                phase = .failed("영상을 만들지 못했어요. 원본 기록은 그대로예요. \(error.localizedDescription)")
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
                saveMessage = "영상을 저장하지 못했어요. 저장 공간과 권한을 확인해 주세요."
            }
        }
    }
}
