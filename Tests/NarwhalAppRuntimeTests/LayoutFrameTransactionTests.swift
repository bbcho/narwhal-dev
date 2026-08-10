import CoreGraphics
import Foundation
import NarwhalAppSupport
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("Layout frame transaction")
struct LayoutFrameTransactionTests {
    @Test("Successful application returns the complete verified live layout")
    func successReturnsCompleteReadback() async throws {
        let fixture = TransactionFixture()

        let outcome = await fixture.transaction.execute(fixture.plan) { true }

        #expect(outcome == .applied(
            originalFrames: fixture.originals,
            appliedFrames: fixture.targets
        ))
        #expect(fixture.writes == [
            FrameWrite(fixture.first, fixture.targets[fixture.first]!),
            FrameWrite(fixture.second, fixture.targets[fixture.second]!),
        ])
    }

    @Test("Failure on the second write restores the first window")
    func secondWriteFailureRollsBackFirst() async throws {
        let fixture = TransactionFixture()
        fixture.failures = [fixture.second: .windowElementNotFound(fixture.second)]

        let outcome = await fixture.transaction.execute(fixture.plan) { true }

        guard case .rolledBack(let originals, let failure) = outcome else {
            Issue.record("Expected a successful rollback, got \(outcome)")
            return
        }
        #expect(originals == fixture.originals)
        #expect(failure.windowID == fixture.second)
        #expect(failure.stage == .apply)
        #expect(fixture.writes == [
            FrameWrite(fixture.first, fixture.targets[fixture.first]!),
            FrameWrite(fixture.second, fixture.targets[fixture.second]!),
            FrameWrite(fixture.first, fixture.originals[fixture.first]!),
        ])
        #expect(fixture.frames == fixture.originals)
    }

    @Test("Final layout validation failure restores every changed window in reverse order")
    func validationFailureRollsBackAllWrites() async throws {
        let fixture = TransactionFixture(
            targets: [
                WindowID(raw: 1): CGRect(x: 0, y: 0, width: 120, height: 100),
                WindowID(raw: 2): CGRect(x: 100, y: 0, width: 120, height: 100),
            ]
        )

        let outcome = await fixture.transaction.execute(fixture.plan) { true }

        guard case .rolledBack(_, let failure) = outcome else {
            Issue.record("Expected validation rollback, got \(outcome)")
            return
        }
        #expect(failure.stage == .validate)
        #expect(fixture.writes.suffix(2) == [
            FrameWrite(fixture.second, fixture.originals[fixture.second]!),
            FrameWrite(fixture.first, fixture.originals[fixture.first]!),
        ])
        #expect(fixture.frames == fixture.originals)
    }

    @Test("A newly observed constraint is returned only after restoring the layout")
    func constraintObservationRollsBackBeforeReturning() async throws {
        let fixture = TransactionFixture()
        fixture.clamps = [
            fixture.second: (
                CGRect(x: 108, y: 0, width: 70, height: 100),
                WindowConstraints(minWidth: 100)
            )
        ]

        let outcome = await fixture.transaction.execute(fixture.plan) { true }

        guard case .constraintObserved(let originals, let observations, let failure) = outcome else {
            Issue.record("Expected a restored constraint observation, got \(outcome)")
            return
        }
        #expect(originals == fixture.originals)
        #expect(observations == [fixture.second: WindowConstraints(minWidth: 100)])
        #expect(failure.windowID == fixture.second)
        #expect(failure.stage == .apply)
        #expect(fixture.writes.suffix(2) == [
            FrameWrite(fixture.second, fixture.originals[fixture.second]!),
            FrameWrite(fixture.first, fixture.originals[fixture.first]!),
        ])
        #expect(fixture.frames == fixture.originals)
    }

    @Test("Rollback failure reports the remaining live frames for reconciliation")
    func rollbackFailureRequiresReconciliation() async throws {
        let fixture = TransactionFixture()
        fixture.failures = [fixture.second: .windowElementNotFound(fixture.second)]
        fixture.rollbackFailures = [fixture.first: .windowElementNotFound(fixture.first)]

        let outcome = await fixture.transaction.execute(fixture.plan) { true }

        guard case .reconciliationRequired(
            let originals,
            let liveFrames,
            let failure,
            let rollbackFailures
        ) = outcome else {
            Issue.record("Expected reconciliation-required outcome, got \(outcome)")
            return
        }
        #expect(originals == fixture.originals)
        #expect(liveFrames[fixture.first] == fixture.targets[fixture.first])
        #expect(liveFrames[fixture.second] == fixture.originals[fixture.second])
        #expect(failure.stage == .apply)
        #expect(rollbackFailures.count == 1)
        #expect(rollbackFailures.first?.windowID == fixture.first)
        #expect(rollbackFailures.first?.stage == .rollback)
    }

    @Test("Rollback is incomplete when WindowServer does not restore with Accessibility")
    func rollbackRequiresBothReadbacks() async throws {
        let fixture = TransactionFixture()
        fixture.failures = [fixture.second: .windowElementNotFound(fixture.second)]
        fixture.staleWindowServerOnRollback = [fixture.first]

        let outcome = await fixture.transaction.execute(fixture.plan) { true }

        guard case .reconciliationRequired(_, _, _, let rollbackFailures) = outcome else {
            Issue.record("Expected WindowServer mismatch to require reconciliation, got \(outcome)")
            return
        }
        #expect(fixture.frames[fixture.first] == fixture.originals[fixture.first])
        #expect(fixture.windowServerFrames[fixture.first] == fixture.targets[fixture.first])
        #expect(rollbackFailures.count == 1)
        #expect(rollbackFailures.first?.windowID == fixture.first)
        #expect(rollbackFailures.first?.stage == .rollback)
    }

    @Test("Missing preflight readback prevents every external write")
    func missingPreflightReadbackHasNoEffects() async throws {
        let fixture = TransactionFixture()
        fixture.readFailures = [fixture.second: .windowServerFrameUnavailable(fixture.second)]

        let outcome = await fixture.transaction.execute(fixture.plan) { true }

        guard case .rolledBack(let originals, let failure) = outcome else {
            Issue.record("Expected a preflight rejection, got \(outcome)")
            return
        }
        #expect(originals == [fixture.first: fixture.originals[fixture.first]!])
        #expect(failure.windowID == fixture.second)
        #expect(failure.stage == .preflight)
        #expect(fixture.writes.isEmpty)
    }

    @Test("Stale currency before the first effect performs no writes")
    func staleBeforeEffectsPerformsNoWrites() async throws {
        let fixture = TransactionFixture()

        let outcome = await fixture.transaction.execute(fixture.plan) { false }

        guard case .rolledBack(_, let failure) = outcome else {
            Issue.record("Expected stale pre-effect rejection, got \(outcome)")
            return
        }
        #expect(failure.stage == .currency)
        #expect(fixture.writes.isEmpty)
        #expect(fixture.frames == fixture.originals)
    }

    @Test("Stale currency after effects restores the prior frames")
    func staleAfterEffectsRollsBack() async throws {
        let fixture = TransactionFixture()
        var checks = 0

        let outcome = await fixture.transaction.execute(fixture.plan) {
            checks += 1
            return checks == 1
        }

        guard case .rolledBack(_, let failure) = outcome else {
            Issue.record("Expected stale post-effect rollback, got \(outcome)")
            return
        }
        #expect(failure.stage == .currency)
        #expect(fixture.writes.suffix(2) == [
            FrameWrite(fixture.second, fixture.originals[fixture.second]!),
            FrameWrite(fixture.first, fixture.originals[fixture.first]!),
        ])
        #expect(fixture.frames == fixture.originals)
    }
}

private struct FrameWrite: Equatable {
    let windowID: WindowID
    let frame: CGRect

    init(_ windowID: WindowID, _ frame: CGRect) {
        self.windowID = windowID
        self.frame = frame
    }
}

@MainActor
private final class TransactionFixture {
    let first = WindowID(raw: 1)
    let second = WindowID(raw: 2)
    let originals: [WindowID: CGRect]
    let targets: [WindowID: CGRect]
    let plan: CommandPlanResult
    var transaction: LayoutFrameTransaction!

    var frames: [WindowID: CGRect]
    var windowServerFrames: [WindowID: CGRect]
    var writes: [FrameWrite] = []
    var failures: [WindowID: AXClientError] = [:]
    var rollbackFailures: [WindowID: AXClientError] = [:]
    var readFailures: [WindowID: AXClientError] = [:]
    var clamps: [WindowID: (CGRect, WindowConstraints)] = [:]
    var staleWindowServerOnRollback: Set<WindowID> = []

    init(targets: [WindowID: CGRect]? = nil) {
        let originals = [
            first: CGRect(x: 0, y: 0, width: 80, height: 100),
            second: CGRect(x: 88, y: 0, width: 80, height: 100),
        ]
        let targets = targets ?? [
            first: CGRect(x: 0, y: 0, width: 100, height: 100),
            second: CGRect(x: 108, y: 0, width: 100, height: 100),
        ]
        self.originals = originals
        self.targets = targets
        frames = originals
        windowServerFrames = originals

        let windows = Dictionary(uniqueKeysWithValues: originals.map { windowID, frame in
            (windowID, WindowMetadata(
                id: windowID,
                bundleID: BundleID(raw: "com.example"),
                title: "Window \(windowID.raw)",
                role: "AXWindow",
                pid: 42,
                frame: frame,
                isResizable: true,
                isMinimized: false
            ))
        })
        let config = Config(
            keymap: Config.default.keymap,
            rules: Config.default.rules,
            zones: Config.default.zones,
            gaps: Gaps(inner: 8, outer: Insets(top: 0, left: 0, bottom: 0, right: 0)),
            border: Config.default.border,
            hud: Config.default.hud,
            dragModifier: Config.default.dragModifier
        )
        let world = World(
            displays: [:],
            activeSpace: nil,
            spaces: [:],
            windows: windows,
            windowDisplay: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: config
        )
        plan = CommandPlanResult(
            focusedWindowID: first,
            desiredLayout: DesiredLayout(
                generation: LayoutGeneration(raw: 1),
                layout: Layout(tiled: targets, floatingZOrder: [], hidden: []),
                delta: LayoutDelta(moves: targets, raises: [], hides: [], shows: [])
            ),
            windows: windows,
            sourceWorld: world,
            plannedWorld: world,
            undoWorld: nil
        )

        let reporter = StartupReporter(
            logPath: "/tmp/narwhal-layout-transaction-\(UUID().uuidString).log"
        )
        transaction = LayoutFrameTransaction(
            frameWriter: WindowFrameWriter(
                writeAccessibility: { [weak self] window, target in
                    guard let self else { return .failed(.windowElementNotFound(window.id)) }
                    self.writes.append(FrameWrite(window.id, target))
                    if target == self.originals[window.id],
                       let error = self.rollbackFailures[window.id] {
                        return .failed(error)
                    }
                    if let error = self.failures[window.id],
                       target != self.originals[window.id] {
                        return .failed(error)
                    }
                    if let clamp = self.clamps[window.id],
                       target != self.originals[window.id] {
                        self.frames[window.id] = clamp.0
                        self.windowServerFrames[window.id] = clamp.0
                        return .clamped(actual: clamp.0, observed: clamp.1)
                    }
                    self.frames[window.id] = target
                    if target != self.originals[window.id]
                        || !self.staleWindowServerOnRollback.contains(window.id) {
                        self.windowServerFrames[window.id] = target
                    }
                    return .converged(actual: target)
                },
                writeTerminal: { _, _ in .failure(.invalidFrame(.null)) },
                readback: { [weak self] window in
                    guard let self else { return .failure(.windowElementNotFound(window.id)) }
                    if let error = self.readFailures.removeValue(forKey: window.id) {
                        return .failure(error)
                    }
                    guard let frame = self.frames[window.id] else {
                        return .failure(.windowServerFrameUnavailable(window.id))
                    }
                    guard let windowServerFrame = self.windowServerFrames[window.id] else {
                        return .failure(.windowServerFrameUnavailable(window.id))
                    }
                    return .success(WindowFrameReadback(
                        accessibility: frame,
                        windowServer: windowServerFrame
                    ))
                }
            ),
            reporter: reporter
        )
    }
}
