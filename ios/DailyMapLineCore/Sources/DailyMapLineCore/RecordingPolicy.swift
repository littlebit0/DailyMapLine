import Foundation

/// Decides which OS location fixes become nodes. Times here are transient and never persisted per node.
/// Experimental rule: within 100 m of an anchor for 5 minutes means stopped; 2 consecutive fixes outside resume.
public struct RecordingPolicy: Sendable {
    public private(set) var isStopped = false
    private var anchor: Coordinate?
    private var anchorTime: Date?
    private var outsideCount = 0
    private var lastNodeTime: Date?

    public init() {}

    /// Returns true when this fix should be saved as a node.
    public mutating func shouldRecord(_ fix: Coordinate, speedKmh: Double, at now: Date) -> Bool {
        guard let currentAnchor = anchor, let since = anchorTime else {
            anchor = fix
            anchorTime = now
            lastNodeTime = now
            return true
        }
        let outside = distanceMeters(currentAnchor, fix) >= 100
        if isStopped {
            guard outside else { outsideCount = 0; return false }
            outsideCount += 1
            guard outsideCount >= 2 else { return false }
            isStopped = false
            outsideCount = 0
            reanchor(fix, now)
            lastNodeTime = now
            return true
        }
        if outside {
            reanchor(fix, now)
        } else if now.timeIntervalSince(since) >= 300 {
            isStopped = true
            return false
        }
        if let last = lastNodeTime, now.timeIntervalSince(last) < recordingInterval(speedKmh: speedKmh) { return false }
        lastNodeTime = now
        return true
    }

    private mutating func reanchor(_ fix: Coordinate, _ now: Date) {
        anchor = fix
        anchorTime = now
    }
}
