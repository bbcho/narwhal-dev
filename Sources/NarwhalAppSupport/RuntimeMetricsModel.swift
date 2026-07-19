import Foundation
import NarwhalCore

public struct RuntimeMetricsState: Equatable, Sendable {
    public let capacityPerMetric: Int
    public let samplesByMetric: [RuntimeMetricKind: [Double]]
    public let sampleCountsByMetric: [RuntimeMetricKind: UInt64]

    public init(capacityPerMetric: Int = 128) {
        precondition(capacityPerMetric > 0, "Runtime metrics capacity must be positive")
        self.capacityPerMetric = capacityPerMetric
        self.samplesByMetric = [:]
        self.sampleCountsByMetric = [:]
    }

    fileprivate init(
        capacityPerMetric: Int,
        samplesByMetric: [RuntimeMetricKind: [Double]],
        sampleCountsByMetric: [RuntimeMetricKind: UInt64]
    ) {
        self.capacityPerMetric = capacityPerMetric
        self.samplesByMetric = samplesByMetric
        self.sampleCountsByMetric = sampleCountsByMetric
    }
}

public func recordingRuntimeMetric(
    _ metric: RuntimeMetricKind,
    durationMilliseconds: Double,
    in state: RuntimeMetricsState
) -> RuntimeMetricsState {
    guard durationMilliseconds.isFinite, durationMilliseconds >= 0 else { return state }

    let existing = state.samplesByMetric[metric] ?? []
    let retained = Array((existing + [durationMilliseconds]).suffix(state.capacityPerMetric))
    var samples = state.samplesByMetric
    samples[metric] = retained
    var counts = state.sampleCountsByMetric
    counts[metric, default: 0] += 1
    return RuntimeMetricsState(
        capacityPerMetric: state.capacityPerMetric,
        samplesByMetric: samples,
        sampleCountsByMetric: counts
    )
}

public func runtimeMetricSummaries(in state: RuntimeMetricsState) -> [RuntimeMetricSummary] {
    RuntimeMetricKind.allCases.compactMap { metric in
        guard let samples = state.samplesByMetric[metric],
              let latest = samples.last,
              !samples.isEmpty
        else { return nil }

        let sorted = samples.sorted()
        return RuntimeMetricSummary(
            metric: metric,
            sampleCount: state.sampleCountsByMetric[metric] ?? UInt64(samples.count),
            retainedSampleCount: samples.count,
            latestMilliseconds: latest,
            medianMilliseconds: nearestRankPercentile(0.50, sortedValues: sorted),
            p95Milliseconds: nearestRankPercentile(0.95, sortedValues: sorted),
            maximumMilliseconds: sorted[sorted.count - 1]
        )
    }
}

private func nearestRankPercentile(_ percentile: Double, sortedValues: [Double]) -> Double {
    let rank = max(1, Int(ceil(percentile * Double(sortedValues.count))))
    return sortedValues[min(rank - 1, sortedValues.count - 1)]
}
