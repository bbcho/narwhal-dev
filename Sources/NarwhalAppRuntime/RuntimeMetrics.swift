import Foundation
import NarwhalAppSupport
import NarwhalCore
import os.signpost

final class RuntimeMetrics: @unchecked Sendable {
    struct Interval {
        let metric: RuntimeMetricKind
        let startedAt: TimeInterval
        let signpostID: OSSignpostID
    }

    private let lock = NSLock()
    private let log = OSLog(subsystem: "ca.quantim.narwhal", category: "runtime")
    private var state: RuntimeMetricsState

    init(capacityPerMetric: Int = 128) {
        state = RuntimeMetricsState(capacityPerMetric: capacityPerMetric)
    }

    func begin(_ metric: RuntimeMetricKind) -> Interval {
        let signpostID = OSSignpostID(log: log)
        os_signpost(
            .begin,
            log: log,
            name: signpostName(for: metric),
            signpostID: signpostID
        )
        return Interval(
            metric: metric,
            startedAt: ProcessInfo.processInfo.systemUptime,
            signpostID: signpostID
        )
    }

    func end(_ interval: Interval?) {
        guard let interval else { return }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - interval.startedAt)
        os_signpost(
            .end,
            log: log,
            name: signpostName(for: interval.metric),
            signpostID: interval.signpostID
        )
        record(interval.metric, durationMilliseconds: elapsed * 1_000)
    }

    func record(_ metric: RuntimeMetricKind, durationMilliseconds: Double) {
        lock.lock()
        state = recordingRuntimeMetric(
            metric,
            durationMilliseconds: durationMilliseconds,
            in: state
        )
        lock.unlock()
    }

    func summaries() -> [RuntimeMetricSummary] {
        lock.lock()
        let snapshot = state
        lock.unlock()
        return runtimeMetricSummaries(in: snapshot)
    }

    private func signpostName(for metric: RuntimeMetricKind) -> StaticString {
        switch metric {
        case .windowSnapshot:
            return "WindowSnapshot"
        case .focusedWindowSnapshot:
            return "FocusedWindowSnapshot"
        case .layoutPlan:
            return "LayoutPlan"
        case .coordinatedFrameWrite:
            return "CoordinatedFrameWrite"
        case .manualResizeHandoff:
            return "ManualResizeHandoff"
        case .layoutTransaction:
            return "LayoutTransaction"
        case .layoutRollback:
            return "LayoutRollback"
        case .workspaceReconciliation:
            return "WorkspaceReconciliation"
        case .restoreWrite:
            return "RestoreWrite"
        }
    }
}
