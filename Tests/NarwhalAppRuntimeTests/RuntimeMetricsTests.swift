import Testing
import NarwhalCore
@testable import NarwhalAppRuntime

@Suite("Runtime metrics recorder")
struct RuntimeMetricsTests {
    @Test("A completed interval records a nonnegative duration")
    func completedIntervalIsRecorded() {
        let metrics = RuntimeMetrics(capacityPerMetric: 4)

        let interval = metrics.begin(.windowSnapshot)
        metrics.end(interval)

        let summary = metrics.summaries().first
        #expect(summary?.metric == .windowSnapshot)
        #expect(summary?.sampleCount == 1)
        #expect(summary?.latestMilliseconds ?? -1 >= 0)
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
