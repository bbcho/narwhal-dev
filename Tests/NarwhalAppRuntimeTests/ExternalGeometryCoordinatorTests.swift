import CoreGraphics
import Foundation
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("External geometry coordinator")
struct ExternalGeometryCoordinatorTests {
    @Test("Thirty resize notifications settle into one handoff with the latest geometry")
    func burstUsesLatestEventOnce() async {
        let scheduler = GeometrySettleScheduler()
        let windowID = WindowID(raw: 44)
        var handoffs: [AXEvent] = []
        let coordinator = ExternalGeometryCoordinator(
            settleInterval: 0.120,
            schedule: scheduler.schedule
        ) { event, _ in
            handoffs.append(event)
        }

        for width in 500..<530 {
            coordinator.observe(
                .windowResized(windowID, CGSize(width: width, height: 700)),
                snapshot: nil
            )
        }

        #expect(coordinator.pendingCount == 1)
        #expect(scheduler.activeCount == 1)
        #expect(handoffs.isEmpty)

        await scheduler.fireLatest()

        #expect(handoffs == [
            .windowResized(windowID, CGSize(width: 529, height: 700))
        ])
        #expect(coordinator.pendingCount == 0)
    }

    @Test("A newer burst waits behind an active transaction and still uses only its latest event")
    func newerBurstWaitsForActiveTransaction() async {
        let scheduler = GeometrySettleScheduler()
        let gate = WorkspaceMutationGate()
        let windowID = WindowID(raw: 45)
        var releaseFirst: CheckedContinuation<Void, Never>?
        var handoffs: [AXEvent] = []
        let coordinator = ExternalGeometryCoordinator(
            settleInterval: 0.120,
            schedule: scheduler.schedule
        ) { event, _ in
            await gate.perform {
                handoffs.append(event)
                if handoffs.count == 1 {
                    await withCheckedContinuation { continuation in
                        releaseFirst = continuation
                    }
                }
            }
        }

        coordinator.observe(
            .windowResized(windowID, CGSize(width: 600, height: 700)),
            snapshot: nil
        )
        let first = Task { @MainActor in await scheduler.fireLatest() }
        while releaseFirst == nil {
            await Task.yield()
        }

        coordinator.observe(
            .windowResized(windowID, CGSize(width: 610, height: 700)),
            snapshot: nil
        )
        coordinator.observe(
            .windowResized(windowID, CGSize(width: 620, height: 700)),
            snapshot: nil
        )
        let second = Task { @MainActor in await scheduler.fireLatest() }
        await Task.yield()
        #expect(handoffs.count == 1)

        releaseFirst?.resume()
        await first.value
        await second.value

        #expect(handoffs == [
            .windowResized(windowID, CGSize(width: 600, height: 700)),
            .windowResized(windowID, CGSize(width: 620, height: 700)),
        ])
    }
}

@MainActor
private final class GeometrySettleScheduler {
    private final class Entry {
        let action: @MainActor () async -> Void
        var cancelled = false

        init(action: @escaping @MainActor () async -> Void) {
            self.action = action
        }
    }

    private var entries: [Entry] = []

    var activeCount: Int {
        entries.count(where: { !$0.cancelled })
    }

    func schedule(
        _ interval: TimeInterval,
        _ action: @escaping @MainActor () async -> Void
    ) -> @MainActor () -> Void {
        let entry = Entry(action: action)
        entries.append(entry)
        return { entry.cancelled = true }
    }

    func fireLatest() async {
        guard let entry = entries.last(where: { !$0.cancelled }) else { return }
        entry.cancelled = true
        await entry.action()
    }
}
