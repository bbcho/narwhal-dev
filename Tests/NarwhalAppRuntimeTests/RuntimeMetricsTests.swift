import Foundation
import Testing
import NarwhalCore
@testable import NarwhalAppRuntime

@Suite("Runtime metrics recorder")
struct RuntimeMetricsTests {
    @Test("A completed interval records its elapsed time in milliseconds")
    func completedIntervalIsRecorded() {
        let clock = UptimeSequence([10.0, 10.25])
        let metrics = RuntimeMetrics(capacityPerMetric: 4, uptime: clock.next)

        let interval = metrics.begin(.windowSnapshot)
        metrics.end(interval)

        let summary = metrics.summaries().first
        #expect(summary?.metric == .windowSnapshot)
        #expect(summary?.sampleCount == 1)
        #expect(summary?.latestMilliseconds == 250)
    }

    @Test("An interval whose clock reading goes backwards records zero, not a negative duration")
    func backwardsClockRecordsZero() {
        let clock = UptimeSequence([10.0, 9.5])
        let metrics = RuntimeMetrics(capacityPerMetric: 4, uptime: clock.next)

        metrics.end(metrics.begin(.windowSnapshot))

        #expect(metrics.summaries().first?.latestMilliseconds == 0)
    }

    @Test("Concurrent recorders retain an exact total and bounded samples")
    func concurrentRecordingIsSerialized() async {
        let metrics = RuntimeMetrics(capacityPerMetric: 8)

        await withTaskGroup(of: Void.self) { group in
            for value in 0..<200 {
                group.addTask {
                    metrics.record(.layoutPlan, durationMilliseconds: Double(value))
                }
            }
        }

        let summary = metrics.summaries().first
        #expect(summary?.metric == .layoutPlan)
        #expect(summary?.sampleCount == 200)
        #expect(summary?.retainedSampleCount == 8)
    }
}

/// Returns the given uptime readings in order, one per call.
private final class UptimeSequence: @unchecked Sendable {
    private var readings: [TimeInterval]

    init(_ readings: [TimeInterval]) {
        self.readings = readings
    }

    func next() -> TimeInterval {
        readings.removeFirst()
    }
}
