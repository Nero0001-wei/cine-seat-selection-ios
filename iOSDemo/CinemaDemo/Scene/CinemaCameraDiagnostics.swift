import Foundation
import OSLog
import QuartzCore

/// Opt-in CPU/display-link timing. These values do not measure GPU execution,
/// presented frames, or FPS. Enable with the `--animation-metrics` launch argument.
@MainActor
final class CinemaCameraDiagnostics {
    private static let isEnabled = ProcessInfo.processInfo.arguments.contains("--animation-metrics")
    private static let logger = Logger(subsystem: "com.cine.seatdemo", category: "CameraTiming")

    private var label = ""
    private var startedAt: CFTimeInterval?
    private var previousTick: CFTimeInterval = 0
    private var intervalsMs: [Double] = []

    /// Starting another sample discards any unfinished transition sample.
    func begin(label: String) {
        guard Self.isEnabled else { return }
        self.label = label
        let now = CACurrentMediaTime()
        startedAt = now
        previousTick = now
        intervalsMs.removeAll(keepingCapacity: true)
        intervalsMs.reserveCapacity(160)
    }

    /// Pass `CACurrentMediaTime()` from inside the CADisplayLink callback.
    /// The first interval starts at begin(), so it includes preparation delays.
    /// CADisplayLink.timestamp describes a display frame, not callback entry time.
    func tick(timestamp: CFTimeInterval) {
        guard Self.isEnabled, startedAt != nil, timestamp.isFinite else { return }
        let intervalMs = max(0, timestamp - previousTick) * 1_000
        intervalsMs.append(intervalMs)
        previousTick = max(previousTick, timestamp)
    }

    func finish() {
        guard Self.isEnabled, let startedAt else { return }
        self.startedAt = nil
        let totalMs = max(0, CACurrentMediaTime() - startedAt) * 1_000
        let sorted = intervalsMs.sorted()
        let percentileIndex = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        let p95Ms = sorted.isEmpty ? 0 : sorted[percentileIndex]
        let firstTickMs = intervalsMs.first ?? 0
        let maxTickMs = sorted.last ?? 0
        let countOver33ms = intervalsMs.lazy.filter { $0 > 33 }.count
        let message = "camera_timing event=transition label=\(String(reflecting: label))"
            + " totalMs=\(Self.number(totalMs))"
            + " firstTickMs=\(Self.number(firstTickMs))"
            + " maxTickMs=\(Self.number(maxTickMs))"
            + " p95Ms=\(Self.number(p95Ms))"
            + " countOver33ms=\(countOver33ms)"
            + " tickCount=\(intervalsMs.count)"
        Self.logger.info("\(message, privacy: .public)")
        intervalsMs.removeAll(keepingCapacity: true)
    }

    /// Call around a synchronous preparation step, not once per animation frame.
    static func recordUpdate(milliseconds: Double, label: String) {
        guard isEnabled else { return }
        let message = "camera_timing event=update label=\(String(reflecting: label))"
            + " milliseconds=\(number(max(0, milliseconds)))"
        logger.info("\(message, privacy: .public)")
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
