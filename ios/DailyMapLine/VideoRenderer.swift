import AVFoundation
import DailyMapLineCore
import MapLibre
import UIKit

struct VideoFailure: LocalizedError {
    let errorDescription: String?
}

/// Renders frames from the output timeline, so generation time never changes playback length.
@MainActor
enum VideoRenderer {
    private static let pointSize = CGSize(width: 360, height: 640)
    private static let pixelScale: CGFloat = 2
    private static let fps = 30
    /// 57 pt on a 360 pt wide frame stands in for the 1.5 cm scale bar. Not a physical guarantee.
    private static let scaleBarPoints = 57.0

    static func render(date: String, timeline: VideoTimeline, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let style = MapStyle.url else { throw VideoFailure(errorDescription: "지도 스타일을 준비하지 못했어요.") }
        guard timeline.lengthMeters > 0 else { throw VideoFailure(errorDescription: "영상을 만들 수 있는 이동 경로가 없어요.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DailyMapLine-\(date).mp4")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = Int(pointSize.width * pixelScale), height = Int(pointSize.height * pixelScale)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoFailure(errorDescription: "영상 파일을 시작하지 못했어요.") }
        writer.startSession(atSourceTime: .zero)

        let turns = timeline.runs.flatMap { directionChanges($0) }.map(\.coordinate)
        let frames = max(1, Int((timeline.durationSeconds * Double(fps)).rounded(.up)))
        var scale = 1.0
        for index in 0...frames {
            let position = timeline.position(at: Double(index) / Double(frames))
            guard let frame = timeline.frame(at: position) else { continue }
            scale += (frame.targetScaleKm - scale) * min(1, 7.0 / Double(fps))
            let snapshot = try await snapshot(style: style, center: frame.center, scaleKm: scale)
            let traces = timeline.traces(upTo: position)
            let image = compose(snapshot, traces: traces, turns: turns.filter { turn in traces.contains { $0.contains(turn) } }, date: date, scaleKm: scale)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            guard let pool = adaptor.pixelBufferPool, let buffer = pixelBuffer(image, pool: pool) else {
                throw VideoFailure(errorDescription: "영상 프레임을 만들지 못했어요.")
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) else {
                throw writer.error ?? VideoFailure(errorDescription: "영상 프레임을 쓰지 못했어요.")
            }
            progress(Double(index) / Double(frames))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoFailure(errorDescription: "영상을 저장하지 못했어요.") }
        return url
    }

    private static func snapshot(style: URL, center: Coordinate, scaleKm: Double) async throws -> MLNMapSnapshot {
        let metersPerPoint = scaleKm * 1000 / scaleBarPoints
        let zoom = log2(cos(center.lat * .pi / 180) * 40075016.686 / (512 * metersPerPoint))
        let camera = MLNMapCamera()
        camera.centerCoordinate = center.location
        let options = MLNMapSnapshotOptions(styleURL: style, camera: camera, size: pointSize)
        options.zoomLevel = zoom
        options.scale = pixelScale
        options.showsLogo = false
        let snapshotter = MLNMapSnapshotter(options: options)
        return try await withCheckedThrowingContinuation { continuation in
            snapshotter.start { snapshot, error in
                if let snapshot { continuation.resume(returning: snapshot) } else {
                    continuation.resume(throwing: error ?? VideoFailure(errorDescription: "지도 화면을 그리지 못했어요."))
                }
            }
        }
    }

    private static func compose(_ snapshot: MLNMapSnapshot, traces: [[Coordinate]], turns: [Coordinate], date: String, scaleKm: Double) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = pixelScale
        format.opaque = true
        let blue = UIColor(red: 0.141, green: 0.490, blue: 0.867, alpha: 1)
        return UIGraphicsImageRenderer(size: pointSize, format: format).image { renderer in
            snapshot.image.draw(at: .zero)
            let context = renderer.cgContext
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for (color, width) in [(UIColor.white, 4.5), (blue, 2.5)] as [(UIColor, CGFloat)] {
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(width)
                for trace in traces {
                    for (index, coordinate) in trace.enumerated() {
                        let point = snapshot.point(for: coordinate.location)
                        if index == 0 { context.move(to: point) } else { context.addLine(to: point) }
                    }
                    context.strokePath()
                }
            }
            for turn in turns {
                let point = snapshot.point(for: turn.location)
                let circle = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
                context.setFillColor(blue.cgColor)
                context.fillEllipse(in: circle)
                context.setStrokeColor(UIColor.white.cgColor)
                context.setLineWidth(1)
                context.strokeEllipse(in: circle)
            }
            drawLabel(date.replacingOccurrences(of: "-", with: "."), at: CGPoint(x: 14, y: 16), size: 12)
            context.setStrokeColor(UIColor(red: 0.157, green: 0.275, blue: 0.357, alpha: 1).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 15, y: 584))
            context.addLine(to: CGPoint(x: 15 + scaleBarPoints, y: 584))
            context.strokePath()
            drawLabel(String(format: "%.1f km", scaleKm), at: CGPoint(x: 11, y: 564), size: 9)
            drawLabel("Protomaps · Map data © OpenStreetMap contributors · ODbL", at: CGPoint(x: 11, y: 592), size: 8)
        }
    }

    private static func drawLabel(_ text: String, at point: CGPoint, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: UIColor(red: 0.145, green: 0.243, blue: 0.329, alpha: 1),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = CGRect(origin: point, size: string.size()).insetBy(dx: -4, dy: -2)
        UIColor.white.withAlphaComponent(0.9).setFill()
        UIRectFill(bounds)
        string.draw(at: point)
    }

    private static func pixelBuffer(_ image: UIImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer, let cgImage = image.cgImage else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
        return buffer
    }
}
