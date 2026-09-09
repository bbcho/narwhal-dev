#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import CoreGraphics
import Foundation
import NarwhalCore
import Testing

struct TwoByTwoWindowIDs {
    let topLeft: WindowID
    let bottomLeft: WindowID
    let topRight: WindowID
    let bottomRight: WindowID
}

func expectedTwoByTwoFrames(
    ids: TwoByTwoWindowIDs,
    visibleFrame: CGRect,
    innerGap: Double
) -> [WindowID: CGRect] {
    let xBoundary = verifierSplitBoundary(visibleFrame.midX)
    let yBoundary = verifierSplitBoundary(visibleFrame.midY)
    let inset = CGFloat(innerGap) / 2
    let cells: [WindowID: CGRect] = [
        ids.topLeft: CGRect(
            x: visibleFrame.minX,
            y: visibleFrame.minY,
            width: xBoundary - visibleFrame.minX,
            height: yBoundary - visibleFrame.minY
        ),
        ids.bottomLeft: CGRect(
            x: visibleFrame.minX,
            y: yBoundary,
            width: xBoundary - visibleFrame.minX,
            height: visibleFrame.maxY - yBoundary
        ),
        ids.topRight: CGRect(
            x: xBoundary,
            y: visibleFrame.minY,
            width: visibleFrame.maxX - xBoundary,
            height: yBoundary - visibleFrame.minY
        ),
        ids.bottomRight: CGRect(
            x: xBoundary,
            y: yBoundary,
            width: visibleFrame.maxX - xBoundary,
            height: visibleFrame.maxY - yBoundary
        )
    ]
    return cells.mapValues {
        canonicalFrameWriteTarget($0.insetBy(dx: inset, dy: inset).standardized)
    }
}

private func verifierSplitBoundary(_ value: CGFloat) -> CGFloat {
    let nearestInteger = value.rounded()
    let noise = max(1, abs(value)) * CGFloat.ulpOfOne * 16
    return abs(value - nearestInteger) <= noise ? nearestInteger : value.rounded(.up)
}

func expectedBottomRowResize(
    before: [WindowID: CGRect],
    ids: TwoByTwoWindowIDs,
    sourceFrame: CGRect,
    innerGap: Double
) -> [WindowID: CGRect] {
    guard let bottomRight = before[ids.bottomRight] else { return before }
    var after = before
    after[ids.bottomLeft] = sourceFrame
    let siblingMinX = sourceFrame.maxX + CGFloat(innerGap)
    after[ids.bottomRight] = CGRect(
        x: siblingMinX,
        y: bottomRight.minY,
        width: bottomRight.maxX - siblingMinX,
        height: bottomRight.height
    )
    return after
}

@Suite("Production manual resize expectation model")
struct ProductionManualResizeExpectationTests {
    @Test("Two-by-two geometry preserves eight-point gaps", arguments: [
        CGRect(x: 0, y: 0, width: 1_200, height: 800),
        CGRect(x: 0, y: 33, width: 1_512, height: 873),
        CGRect(x: -1_512, y: 48, width: 1_512, height: 873)
    ])
    func twoByTwoGeometry(visibleFrame: CGRect) throws {
        let ids = testIDs
        let frames = expectedTwoByTwoFrames(ids: ids, visibleFrame: visibleFrame, innerGap: 8)
        #expect(frames.count == 4)
        #expect(innerGapViolations(planned: frames, actual: frames, innerGap: 8).isEmpty)
        #expect(frames.values.allSatisfy { visibleFrame.contains($0) })
        let source = try #require(frames[ids.bottomLeft])
        let resized = CGRect(x: source.minX, y: source.minY, width: source.width + 48, height: source.height)
        let after = expectedBottomRowResize(before: frames, ids: ids, sourceFrame: resized, innerGap: 8)
        #expect(after[ids.topLeft] == frames[ids.topLeft])
        #expect(after[ids.topRight] == frames[ids.topRight])
        #expect(after[ids.bottomLeft] == resized)
        #expect(try #require(after[ids.bottomRight]).minX == resized.maxX + 8)
        #expect(innerGapViolations(planned: after, actual: after, innerGap: 8).isEmpty)
    }

    @Test("Fresh window selection supports exact and unique-token identity")
    func freshWindowSelection() throws {
        let exact = metadata(id: 10, title: "Narwhal Production Verifier exact")
        let other = metadata(id: 11, title: "Narwhal Production Verifier token")
        let base = FreshWindowSelectionRequest(
            identity: .exact(exact.id),
            protectedWindowIDs: [],
            expectedBundleID: "com.apple.Terminal",
            allowedPIDs: [777],
            requiredTitleSubstring: "Narwhal Production Verifier",
            minimumSize: CGSize(width: 300, height: 180)
        )
        #expect(try selectFreshWindow(request: base, candidates: [other, exact]).get().id == exact.id)
        let token = FreshWindowSelectionRequest(
            identity: .uniqueToken,
            protectedWindowIDs: [exact.id],
            expectedBundleID: "com.apple.Terminal",
            allowedPIDs: [777],
            requiredTitleSubstring: "token",
            minimumSize: CGSize(width: 300, height: 180)
        )
        #expect(try selectFreshWindow(request: token, candidates: [exact, other]).get().id == other.id)
        #expect(selectFreshWindow(request: token, candidates: [other, metadata(id: 12, title: other.title)]) == .failure(.ambiguous([other.id, WindowID(raw: 12)])))
    }

    private var testIDs: TwoByTwoWindowIDs {
        TwoByTwoWindowIDs(
            topLeft: WindowID(raw: 1),
            bottomLeft: WindowID(raw: 2),
            topRight: WindowID(raw: 3),
            bottomRight: WindowID(raw: 4)
        )
    }

    private func metadata(id: UInt32, title: String) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: id),
            bundleID: BundleID(raw: "com.apple.Terminal"),
            title: title,
            role: "AXWindow",
            pid: 777,
            frame: CGRect(x: 0, y: 0, width: 400, height: 240),
            isResizable: true,
            isMinimized: false
        )
    }
}

@MainActor
enum ProductionManualResizeVerification {
    static func verifyTwoByTwoTerminalResize() async -> (passed: Bool, message: String) {
        let axClient = AXClient(processID: -1, settleStrategy: .servicingRunLoop)
        var windows: [RealAppOriginal] = []
        var runtime: ProductionRuntimeHarness?
        do {
            try requireUnlockedSession()
            let display = try verificationDisplay()
            var selected = Set<WindowID>()
            for index in 1...4 {
                let window = try await RealAppLaunchSupport.launchTerminal(
                    token: "two-by-two-\(index)",
                    excluding: selected,
                    using: axClient
                )
                selected.insert(window.metadata.id)
                windows.append(window)
            }
            try await stage(windows, on: display, using: axClient)

            let config = Config(
                keymap: Config.default.keymap,
                rules: Config.default.rules,
                zones: Config.default.zones,
                gaps: Gaps(inner: 8, outer: Config.default.gaps.outer),
                border: Config.default.border,
                hud: Config.default.hud,
                dragModifier: Config.default.dragModifier,
                managedRules: Config.default.managedRules
            )
            let activeRuntime = try ProductionRuntimeHarness.start(config: config)
            runtime = activeRuntime
            _ = try await activeRuntime.waitUntilReady()

            let directions: [Direction] = [.left, .left, .right, .right]
            for (window, direction) in zip(windows, directions) {
                try activeRuntime.send(.push(windowID: window.metadata.id, direction: direction))
            }

            let ids = TwoByTwoWindowIDs(
                topLeft: windows[0].metadata.id,
                bottomLeft: windows[1].metadata.id,
                topRight: windows[2].metadata.id,
                bottomRight: windows[3].metadata.id
            )
            let expectedBefore = expectedTwoByTwoFrames(
                ids: ids,
                visibleFrame: display.visibleFrame,
                innerGap: config.gaps.inner
            )
            let before = try await waitForFrames(
                windows,
                expected: expectedBefore,
                using: axClient,
                context: "production 2-by-2 before manual resize"
            )
            try RealFrameAssertions.requireAXAndWindowServerFrames(
                before,
                expected: expectedBefore,
                context: "production 2-by-2 before manual resize"
            )
            try RealFrameAssertions.requireProductionBorders(
                frames: before,
                focusedWindowID: ids.bottomRight,
                ownerPID: activeRuntime.process.processIdentifier,
                display: display,
                context: "production 2-by-2 before manual resize"
            )

            let topLeftID = windows[0].metadata.id
            let bottomLeft = windows[1]
            let topRightID = windows[2].metadata.id
            let bottomRightID = windows[3].metadata.id
            let bottomLeftBefore = try requiredFrame(bottomLeft.metadata.id, in: before)
            let bottomRightBefore = try requiredFrame(bottomRightID, in: before)
            let growth = min(96, bottomRightBefore.width - 320)
            guard growth >= 24 else {
                throw RealAppWindowVerifierFailure(
                    "2-by-2 display leaves insufficient room for a visible manual resize: right=\(bottomRightBefore)"
                )
            }
            let requested = CGRect(
                x: bottomLeftBefore.minX,
                y: bottomLeftBefore.minY,
                width: bottomLeftBefore.width + growth,
                height: bottomLeftBefore.height
            )
            _ = try await activeRuntime.waitUntilIdle()
            try activeRuntime.send(.focus(windowID: bottomLeft.metadata.id))
            let evidence = try activeRuntime.captureEvidenceBaseline()
            let handoffStarted = ProcessInfo.processInfo.systemUptime
            let manualFrame = try await RealAppLaunchSupport.setFrame(
                bottomLeft,
                to: requested,
                using: axClient,
                context: "production 2-by-2 bottom-left manual resize"
            )
            _ = try await activeRuntime.waitForManualResize(from: evidence, deadline: 1.2)

            let expectedAfter = expectedBottomRowResize(
                before: before,
                ids: ids,
                sourceFrame: manualFrame,
                innerGap: config.gaps.inner
            )
            let after = try await waitForFrames(
                windows,
                expected: expectedAfter,
                using: axClient,
                context: "production 2-by-2 after manual resize"
            )
            let handoffDuration = ProcessInfo.processInfo.systemUptime - handoffStarted
            guard handoffDuration <= 1.2 else {
                throw RealAppWindowVerifierFailure(
                    "manual resize handoff exceeded 1.2 seconds: \(handoffDuration)"
                )
            }

            try RealFrameAssertions.requireExactFrames(
                [
                    topLeftID: try requiredFrame(topLeftID, in: after),
                    topRightID: try requiredFrame(topRightID, in: after)
                ],
                expected: [
                    topLeftID: try requiredFrame(topLeftID, in: before),
                    topRightID: try requiredFrame(topRightID, in: before)
                ],
                context: "production 2-by-2 opposite row preservation"
            )
            try RealFrameAssertions.requireAXAndWindowServerFrames(
                after,
                expected: expectedAfter,
                context: "production 2-by-2 after manual resize"
            )
            try RealFrameAssertions.requireProductionBorders(
                frames: after,
                focusedWindowID: bottomLeft.metadata.id,
                ownerPID: activeRuntime.process.processIdentifier,
                display: display,
                context: "production 2-by-2 after manual resize"
            )
            try RealFrameAssertions.requireNoForbiddenRuntimeOutcomes(
                activeRuntime.logText,
                context: "production 2-by-2 manual resize"
            )

            // Moving the right tile's left edge changes its origin as well as its size.
            let rightBefore = try requiredFrame(bottomRightID, in: after)
            let rightRequested = CGRect(
                x: rightBefore.minX - growth,
                y: rightBefore.minY,
                width: rightBefore.width + growth,
                height: rightBefore.height
            )
            _ = try await activeRuntime.waitUntilIdle()
            try activeRuntime.send(.focus(windowID: bottomRightID))
            let rightEvidence = try activeRuntime.captureEvidenceBaseline()
            let rightManualFrame = try await RealAppLaunchSupport.setFrame(
                windows[3],
                to: rightRequested,
                using: axClient,
                context: "production 2-by-2 rightmost left-edge resize"
            )
            _ = try await activeRuntime.waitForManualResize(from: rightEvidence, deadline: 1.2)
            var rightExpected = after
            let leftBefore = try requiredFrame(bottomLeft.metadata.id, in: after)
            rightExpected[bottomRightID] = rightManualFrame
            rightExpected[bottomLeft.metadata.id] = CGRect(
                x: leftBefore.minX,
                y: leftBefore.minY,
                width: rightManualFrame.minX - CGFloat(config.gaps.inner) - leftBefore.minX,
                height: leftBefore.height
            )
            let rightAfter = try await waitForFrames(
                windows,
                expected: rightExpected,
                using: axClient,
                context: "production 2-by-2 rightmost left-edge resize"
            )
            try RealFrameAssertions.requireAXAndWindowServerFrames(
                rightAfter,
                expected: rightExpected,
                context: "production 2-by-2 rightmost left-edge resize"
            )
            try RealFrameAssertions.requireNoForbiddenRuntimeOutcomes(
                activeRuntime.logText,
                context: "production 2-by-2 rightmost left-edge resize"
            )

            _ = try await activeRuntime.waitUntilIdle()
            let dragEvidence = try activeRuntime.captureEvidenceBaseline()
            let dragStartFrame = try requiredFrame(bottomRightID, in: rightAfter)
            let dragStart = CGPoint(x: dragStartFrame.minX + 1, y: dragStartFrame.minY + 40)
            let dragEnd = CGPoint(x: dragStart.x - 72, y: dragStart.y)
            let originalCursor = CGEvent(source: nil)?.location
            defer { if let originalCursor { _ = CGWarpMouseCursorPosition(originalCursor) } }
            _ = CGWarpMouseCursorPosition(dragStart)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: dragStart, mouseButton: .left)?.post(tap: .cghidEventTap)
            await settleLiveVerifier(for: 0.15)
            guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                     mouseCursorPosition: dragStart, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                   mouseCursorPosition: dragEnd, mouseButton: .left)
            else { throw RealAppWindowVerifierFailure("could not create native resize drag events") }
            var released = false
            defer { if !released { up.post(tap: .cghidEventTap) } }
            down.post(tap: .cghidEventTap)
            await settleLiveVerifier(for: 0.1)
            for offset in [CGFloat(3), 12, 24, 48, 72] {
                let point = CGPoint(x: dragStart.x - offset, y: dragStart.y)
                guard let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                         mouseCursorPosition: point, mouseButton: .left)
                else { throw RealAppWindowVerifierFailure("could not create native drag step") }
                drag.post(tap: .cghidEventTap)
                await settleLiveVerifier(for: 0.05)
            }
            await settleLiveVerifier(for: 0.35)
            let heldFrame = try RealAppLaunchSupport.currentMetadata(for: windows[3], using: axClient).frame
            guard heldFrame.minX < dragStartFrame.minX - 24 else {
                let underPointer = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { row -> String? in
                    guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
                          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(dragStart)
                    else { return nil }
                    return "id=\(row[kCGWindowNumber as String] ?? "?") layer=\(row[kCGWindowLayer as String] ?? "?") frame=\(frame)"
                }
                throw RealAppWindowVerifierFailure("native left-edge drag did not resize the real Terminal window: before=\(dragStartFrame) held=\(heldFrame) buttons=\(NSEvent.pressedMouseButtons) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") underPointer=\(underPointer)")
            }
            let heldNeighbor = try RealAppLaunchSupport.currentMetadata(for: bottomLeft, using: axClient).frame
            try RealFrameAssertions.requireExactFrames(
                [bottomLeft.metadata.id: heldNeighbor],
                expected: [bottomLeft.metadata.id: try requiredFrame(bottomLeft.metadata.id, in: rightAfter)],
                context: "native resize pause must not hand off while the button is held"
            )
            up.post(tap: .cghidEventTap)
            released = true
            _ = try await activeRuntime.waitForManualResize(from: dragEvidence, deadline: 1.2)
            var dragExpected = rightAfter
            dragExpected[bottomRightID] = heldFrame
            dragExpected[bottomLeft.metadata.id] = CGRect(
                x: heldNeighbor.minX, y: heldNeighbor.minY,
                width: heldFrame.minX - CGFloat(config.gaps.inner) - heldNeighbor.minX,
                height: heldNeighbor.height
            )
            let dragAfter = try await waitForFrames(
                windows, expected: dragExpected, using: axClient, context: "native rightmost resize after release"
            )
            try RealFrameAssertions.requireAXAndWindowServerFrames(
                dragAfter, expected: dragExpected, context: "native rightmost resize after release"
            )
            try RealFrameAssertions.requireNoForbiddenRuntimeOutcomes(
                activeRuntime.logText, context: "native rightmost resize after release"
            )

            try activeRuntime.stop()
            runtime = nil
            try await RealAppLaunchSupport.cleanup(windows, using: axClient)
            windows.removeAll()
            return (
                true,
                "production 2-by-2 manual resize preserved both top windows from both sides of the bottom seam; left handoff \(handoffDuration)s"
            )
        } catch {
            let runtimeLog = runtime?.logText ?? "runtime not started"
            runtime?.stopBestEffort()
            await RealAppLaunchSupport.cleanupBestEffort(
                windows,
                using: axClient,
                context: "PRODUCTION 2-BY-2 VERIFY"
            )
            return (false, "\(error); runtime log:\n\(runtimeLog)")
        }
    }

    private static func verificationDisplay() throws -> DisplayInfo {
        let displays = DisplayClient().currentDisplays().values.filter {
            $0.visibleFrame.width >= 1_200
                && $0.visibleFrame.height >= 800
                && $0.visibleFrame.width > $0.visibleFrame.height
        }
        guard let display = displays.max(by: { $0.visibleFrame.narwhalArea < $1.visibleFrame.narwhalArea }) else {
            throw RealAppWindowVerifierFailure("2-by-2 verification requires a landscape display at least 1200x800")
        }
        return display
    }

    private static func stage(
        _ windows: [RealAppOriginal],
        on display: DisplayInfo,
        using axClient: AXClient
    ) async throws {
        let visible = display.visibleFrame
        let width = min(480, visible.width / 2 - 40)
        let height = min(300, visible.height / 2 - 40)
        for (index, window) in windows.enumerated() {
            let column = index % 2
            let row = index / 2
            let frame = CGRect(
                x: visible.minX + 20 + CGFloat(column) * (visible.width / 2),
                y: visible.minY + 20 + CGFloat(row) * (visible.height / 2),
                width: width,
                height: height
            )
            _ = try await RealAppLaunchSupport.setFrame(
                window,
                to: frame,
                using: axClient,
                context: "stage Terminal \(index + 1)"
            )
        }
    }

    private static func waitForFrames(
        _ windows: [RealAppOriginal],
        expected: [WindowID: CGRect],
        using axClient: AXClient,
        context: String
    ) async throws -> [WindowID: CGRect] {
        let deadline = Date().addingTimeInterval(4)
        var latest: [WindowID: CGRect] = [:]
        while Date() < deadline {
            latest = try RealFrameAssertions.currentFrames(windows, using: axClient)
            if expected.allSatisfy({ windowID, frame in
                latest[windowID]?.narwhalApproximatelyEquals(
                    frame,
                    tolerance: frameWriteSettleTolerance
                ) == true
            }) {
                return latest
            }
            await settleLiveVerifier(for: 0.04)
        }
        throw RealAppWindowVerifierFailure("\(context) did not settle: expected=\(expected) actual=\(latest)")
    }

    private static func requiredFrame(
        _ windowID: WindowID,
        in frames: [WindowID: CGRect]
    ) throws -> CGRect {
        guard let frame = frames[windowID] else {
            throw RealAppWindowVerifierFailure("missing frame for \(windowID.description)")
        }
        return frame
    }

    private static func requireUnlockedSession() throws {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        let locked = (dictionary["CGSSessionScreenIsLocked"] as? Bool) ?? false
        guard !locked else {
            throw RealAppWindowVerifierFailure("real-app verification requires an unlocked user session")
        }
    }
}
#endif
