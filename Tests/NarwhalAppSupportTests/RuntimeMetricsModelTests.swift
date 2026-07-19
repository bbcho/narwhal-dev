import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Runtime metrics model")
struct RuntimeMetricsModelTests {
    @Test("Recording retains only the newest bounded samples")
    func recordingRetainsNewestBoundedSamples() {
        let initial = RuntimeMetricsState(capacityPerMetric: 3)
        let recorded = [1.0, 2.0, 3.0, 4.0].reduce(initial) { state, duration in
            recordingRuntimeMetric(.windowSnapshot, durationMilliseconds: duration, in: state)
        }

        #expect(recorded.samplesByMetric[.windowSnapshot] == [2, 3, 4])
        #expect(recorded.sampleCountsByMetric[.windowSnapshot] == 4)
    }

    @Test("Invalid durations do not change metrics state")
    func invalidDurationsAreIgnored() {
        let initial = RuntimeMetricsState(capacityPerMetric: 3)

        #expect(recordingRuntimeMetric(.layoutPlan, durationMilliseconds: -Double.infinity, in: initial) == initial)
        #expect(recordingRuntimeMetric(.layoutPlan, durationMilliseconds: .nan, in: initial) == initial)
        #expect(recordingRuntimeMetric(.layoutPlan, durationMilliseconds: -0.1, in: initial) == initial)
    }

    @Test("Summaries are deterministic for unsorted retained samples")
    func summariesAreDeterministic() {
        let state = [8.0, 1.0, 5.0, 3.0, 2.0].reduce(RuntimeMetricsState(capacityPerMetric: 8)) { state, duration in
            recordingRuntimeMetric(.coordinatedFrameWrite, durationMilliseconds: duration, in: state)
        }

        let summary = runtimeMetricSummaries(in: state).first

        #expect(summary == RuntimeMetricSummary(
            metric: .coordinatedFrameWrite,
            sampleCount: 5,
            retainedSampleCount: 5,
            latestMilliseconds: 2,
            medianMilliseconds: 3,
            p95Milliseconds: 8,
            maximumMilliseconds: 8
        ))
    }

    @Test("Summaries follow the stable metric case order")
    func summariesUseStableMetricOrder() {
        let first = recordingRuntimeMetric(
            .restoreWrite,
            durationMilliseconds: 2,
            in: RuntimeMetricsState()
        )
        let second = recordingRuntimeMetric(.windowSnapshot, durationMilliseconds: 1, in: first)

        #expect(runtimeMetricSummaries(in: second).map(\.metric) == [.windowSnapshot, .restoreWrite])
    }
}
