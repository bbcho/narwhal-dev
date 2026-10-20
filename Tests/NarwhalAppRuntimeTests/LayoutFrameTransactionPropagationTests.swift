import CoreGraphics
import Foundation
import NarwhalAppSupport
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("Layout frame transaction write propagation")
struct LayoutFrameTransactionPropagationTests {
    @Test("A constrained leading frame moves only unwritten followers")
    func constrainedFramePropagatesForwardOnce() async throws {
        let left = WindowID(raw: 30)
        let middle = WindowID(raw: 10)
        let right = WindowID(raw: 20)
        let planned = [
            left: CGRect(x: 0, y: 0, width: 500, height: 800),
            middle: CGRect(x: 508, y: 0, width: 500, height: 800),
            right: CGRect(x: 1_016, y: 0, width: 500, height: 800),
        ]
        let originals = [
            left: CGRect(x: 0, y: 0, width: 450, height: 800),
            middle: CGRect(x: 458, y: 0, width: 450, height: 800),
            right: CGRect(x: 916, y: 0, width: 450, height: 800),
        ]
        var observed = originals
        var writes: [(WindowID, CGRect)] = []
        let writer = WindowFrameWriter(
            writeAccessibility: { window, target in
                writes.append((window.id, target))
                let actual = window.id == left
                    ? CGRect(x: target.minX, y: target.minY, width: 490, height: target.height)
                    : target
                observed[window.id] = actual
                return window.id == left
                    ? .constrained(actual: actual)
                    : .converged(actual: actual)
            },
            writeTerminal: { _, _ in
                .failure(.invalidFrame(.null))
            },
            readback: { window in
                guard let frame = observed[window.id] else {
                    return .failure(.windowServerFrameUnavailable(window.id))
                }
                return .success(WindowFrameReadback(
                    accessibility: frame,
                    windowServer: frame
                ))
            }
        )
        let reporter = StartupReporter(
            logPath: "/tmp/narwhal-layout-applier-\(UUID().uuidString).log"
        )
        let transaction = LayoutFrameTransaction(frameWriter: writer, reporter: reporter)

        let outcome = await transaction.execute(
            plan(planned: planned, originals: originals, innerGap: 8)
        ) { true }

        #expect(outcome == .applied(
            originalFrames: originals,
            appliedFrames: [
                left: CGRect(x: 0, y: 0, width: 490, height: 800),
                middle: CGRect(x: 498, y: 0, width: 500, height: 800),
                right: CGRect(x: 1_006, y: 0, width: 500, height: 800),
            ]
        ))
        #expect(writes.map(\.0) == [left, middle, right])
        #expect(writes.filter { $0.0 == left }.count == 1)
        #expect(writes.filter { $0.0 == middle }.count == 1)
        #expect(writes.filter { $0.0 == right }.count == 1)
        let firstWrite = try #require(writes.first)
        let middleWrite = try #require(writes.dropFirst().first)
        let lastWrite = try #require(writes.last)
        #expect(firstWrite.1 == planned[left])
        #expect(middleWrite.1.minX == 498)
        #expect(lastWrite.1.minX == 1_006)
    }

    private func plan(
        planned: [WindowID: CGRect],
        originals: [WindowID: CGRect],
        innerGap: Double
    ) -> CommandPlanResult {
        let windows = Dictionary(uniqueKeysWithValues: planned.map { windowID, frame in
            (
                windowID,
                WindowMetadata(
                id: windowID,
                bundleID: BundleID(raw: "com.example"),
                title: "Test",
                role: "AXWindow",
                pid: 101,
                    frame: originals[windowID] ?? frame,
                isResizable: true,
                isMinimized: false
                )
            )
        })
        let config = Config(
            keymap: Config.default.keymap,
            rules: Config.default.rules,
            zones: Config.default.zones,
            gaps: Gaps(
                inner: innerGap,
                outer: Insets(top: 0, left: 0, bottom: 0, right: 0)
            ),
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
        return CommandPlanResult(
            focusedWindowID: nil,
            desiredLayout: DesiredLayout(
                generation: LayoutGeneration(raw: 1),
                layout: Layout(tiled: planned, floatingZOrder: [], hidden: []),
                delta: LayoutDelta(moves: planned, raises: [], hides: [], shows: [])
            ),
            windows: windows,
            sourceWorld: world,
            plannedWorld: world,
            undoWorld: nil
        )
    }
}
