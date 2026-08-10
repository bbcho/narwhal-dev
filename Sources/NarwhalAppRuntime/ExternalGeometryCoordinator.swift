import Foundation
import NarwhalAppSupport
import NarwhalCore

typealias ExternalGeometrySettleScheduler = @MainActor (
    TimeInterval,
    @escaping @MainActor () async -> Void
) -> @MainActor () -> Void

@MainActor
final class ExternalGeometryCoordinator {
    nonisolated static let settleInterval: TimeInterval = 0.120

    private struct PendingEvent {
        let generation: UInt64
        let event: AXEvent
        let snapshot: FocusedWindowSnapshot?
        var cancel: @MainActor () -> Void
    }

    private let settleInterval: TimeInterval
    private let schedule: ExternalGeometrySettleScheduler
    private let handoff: @MainActor (AXEvent, FocusedWindowSnapshot?) async -> Void
    private var nextGeneration: UInt64 = 0
    private var pendingByWindowID: [WindowID: PendingEvent] = [:]

    init(
        settleInterval: TimeInterval = ExternalGeometryCoordinator.settleInterval,
        schedule: @escaping ExternalGeometrySettleScheduler = scheduleExternalGeometrySettle,
        handoff: @escaping @MainActor (AXEvent, FocusedWindowSnapshot?) async -> Void
    ) {
        self.settleInterval = settleInterval
        self.schedule = schedule
        self.handoff = handoff
    }

    var pendingCount: Int {
        pendingByWindowID.count
    }

    func observe(_ event: AXEvent, snapshot: FocusedWindowSnapshot?) {
        guard let windowID = externalGeometryWindowID(for: event) else { return }
        pendingByWindowID[windowID]?.cancel()
        nextGeneration &+= 1
        let generation = nextGeneration
        pendingByWindowID[windowID] = PendingEvent(
            generation: generation,
            event: event,
            snapshot: snapshot,
            cancel: {}
        )
        let cancel = schedule(settleInterval) { [weak self] in
            await self?.fire(windowID: windowID, generation: generation)
        }
        guard pendingByWindowID[windowID]?.generation == generation else {
            cancel()
            return
        }
        pendingByWindowID[windowID]?.cancel = cancel
    }

    func cancel(windowID: WindowID) {
        pendingByWindowID.removeValue(forKey: windowID)?.cancel()
    }

    func cancelAll() {
        pendingByWindowID.values.forEach { $0.cancel() }
        pendingByWindowID.removeAll()
    }

    private func fire(windowID: WindowID, generation: UInt64) async {
        guard let pending = pendingByWindowID[windowID],
              pending.generation == generation
        else { return }
        pendingByWindowID.removeValue(forKey: windowID)
        await handoff(pending.event, pending.snapshot)
    }
}

@MainActor
private func scheduleExternalGeometrySettle(
    interval: TimeInterval,
    action: @escaping @MainActor () async -> Void
) -> @MainActor () -> Void {
    let timer = Timer(timeInterval: interval, repeats: false) { _ in
        Task { @MainActor in
            await action()
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    return { timer.invalidate() }
}
