import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Window stack visibility model")
struct WindowStackVisibilityModelTests {
    @Test("Target is visible when no earlier window overlaps it")
    func targetVisibleWithoutEarlierOverlap() {
        let target = WindowID(raw: 10)
        let decision = windowStackVisibility(
            target: target,
            frontToBackWindows: [
                entry(11, x: 500, y: 0, width: 300, height: 300),
                entry(target.raw, x: 0, y: 0, width: 300, height: 300)
            ]
        )

        #expect(decision == .visible)
    }

    @Test("Earlier overlapping window blocks target visibility")
    func earlierOverlappingWindowBlocksTargetVisibility() {
        let target = WindowID(raw: 20)
        let blocker = WindowID(raw: 21)
        let decision = windowStackVisibility(
            target: target,
            frontToBackWindows: [
                entry(blocker.raw, x: 20, y: 20, width: 300, height: 300),
                entry(target.raw, x: 0, y: 0, width: 300, height: 300)
            ]
        )

        #expect(decision == .blockedBy(blocker))
    }

    @Test("Windows behind target cannot block visibility")
    func windowsBehindTargetCannotBlockVisibility() {
        let target = WindowID(raw: 30)
        let decision = windowStackVisibility(
            target: target,
            frontToBackWindows: [
                entry(target.raw, x: 0, y: 0, width: 300, height: 300),
                entry(31, x: 20, y: 20, width: 300, height: 300)
            ]
        )

        #expect(decision == .visible)
    }

    @Test("Transparent windows cannot block visibility")
    func transparentWindowsCannotBlockVisibility() {
        let target = WindowID(raw: 35)
        let decision = windowStackVisibility(
            target: target,
            frontToBackWindows: [
                WindowStackEntry(
                    id: WindowID(raw: 36),
                    frame: CGRect(x: 20, y: 20, width: 300, height: 300),
                    alpha: 0
                ),
                entry(target.raw, x: 0, y: 0, width: 300, height: 300)
            ]
        )

        #expect(decision == .visible)
    }

    @Test("Missing target is explicit")
    func missingTargetIsExplicit() {
        #expect(windowStackVisibility(
            target: WindowID(raw: 40),
            frontToBackWindows: [entry(41, x: 0, y: 0, width: 300, height: 300)]
        ) == .targetMissing)
    }

    @Test("Focus border stacking keeps an already visible border")
    func focusBorderStackingKeepsVisibleBorder() {
        let target = WindowID(raw: 60)
        let border = WindowID(raw: 61)

        #expect(focusBorderStackingDecision(
            target: target,
            border: border,
            frontToBackWindows: [
                entry(border.raw, x: -1, y: -1, width: 302, height: 302),
                entry(target.raw, x: 0, y: 0, width: 300, height: 300)
            ],
            ignoredWindowIDs: [border]
        ) == .keepVisible)
    }

    @Test("Focus border stacking restacks a missing or buried border")
    func focusBorderStackingRestacksMissingOrBuriedBorder() {
        let target = WindowID(raw: 70)
        let border = WindowID(raw: 71)
        let targetEntry = entry(target.raw, x: 0, y: 0, width: 300, height: 300)

        #expect(focusBorderStackingDecision(
            target: target,
            border: nil,
            frontToBackWindows: [targetEntry],
            ignoredWindowIDs: []
        ) == .restack)
        #expect(focusBorderStackingDecision(
            target: target,
            border: border,
            frontToBackWindows: [
                targetEntry,
                entry(border.raw, x: -1, y: -1, width: 302, height: 302)
            ],
            ignoredWindowIDs: [border]
        ) == .restack)
    }

    @Test("Focus border stacking hides an obscured or missing target")
    func focusBorderStackingHidesInvalidTarget() {
        let target = WindowID(raw: 80)
        let border = WindowID(raw: 81)
        let blocker = WindowID(raw: 82)

        #expect(focusBorderStackingDecision(
            target: target,
            border: border,
            frontToBackWindows: [
                entry(border.raw, x: -1, y: -1, width: 302, height: 302),
                entry(blocker.raw, x: 20, y: 20, width: 100, height: 100),
                entry(target.raw, x: 0, y: 0, width: 300, height: 300)
            ],
            ignoredWindowIDs: [border]
        ) == .hideBlockedBy(blocker))
        #expect(focusBorderStackingDecision(
            target: target,
            border: border,
            frontToBackWindows: [
                entry(border.raw, x: -1, y: -1, width: 302, height: 302),
                entry(blocker.raw, x: 20, y: 20, width: 100, height: 100)
            ],
            ignoredWindowIDs: [border]
        ) == .hideTargetMissing)
    }

    @Test("Focus border stacking ignores Narwhal overlays and non-overlapping windows")
    func focusBorderStackingIgnoresNonBlockers() {
        let target = WindowID(raw: 90)
        let border = WindowID(raw: 91)
        let overlay = WindowID(raw: 92)
        let unrelated = WindowID(raw: 93)

        #expect(focusBorderStackingDecision(
            target: target,
            border: border,
            frontToBackWindows: [
                entry(overlay.raw, x: 20, y: 20, width: 100, height: 100),
                entry(unrelated.raw, x: 500, y: 0, width: 300, height: 300),
                entry(border.raw, x: -1, y: -1, width: 302, height: 302),
                entry(target.raw, x: 0, y: 0, width: 300, height: 300)
            ],
            ignoredWindowIDs: [border, overlay]
        ) == .keepVisible)
    }

    @Test("Focus border stacking ignores target companion surfaces but not sibling windows")
    func focusBorderStackingClassifiesSameProcessSurfaces() {
        let target = WindowID(raw: 94)
        let border = WindowID(raw: 95)
        let companion = WindowID(raw: 96)
        let sibling = WindowID(raw: 97)
        let targetEntry = entry(target.raw, x: 0, y: 0, width: 600, height: 400, ownerPID: 42)
        let borderEntry = entry(border.raw, x: -1, y: -1, width: 602, height: 402, ownerPID: 7)

        #expect(focusBorderStackingDecision(
            target: target,
            border: border,
            frontToBackWindows: [
                borderEntry,
                entry(companion.raw, x: 0, y: 0, width: 600, height: 44, ownerPID: 42),
                targetEntry
            ],
            ignoredWindowIDs: [border]
        ) == .keepVisible)
        #expect(focusBorderStackingDecision(
            target: target,
            border: border,
            frontToBackWindows: [
                borderEntry,
                entry(sibling.raw, x: 40, y: 40, width: 300, height: 200, ownerPID: 42),
                targetEntry
            ],
            ignoredWindowIDs: [border]
        ) == .hideBlockedBy(sibling))
    }

    @Test("Tiled border target visibility requires live matching bounds")
    func tiledBorderTargetVisibilityRequiresLiveMatchingBounds() {
        let target = WindowID(raw: 50)
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let borderTarget = FocusBorderTarget(windowID: target, frame: frame, cornerRadius: 12)

        #expect(tiledBorderTargetVisibility(
            target: borderTarget,
            liveWindows: [WindowStackEntry(id: target, frame: CGRect(x: 11, y: 21, width: 299, height: 201))],
            frameTolerance: 2
        ) == .show)

        #expect(tiledBorderTargetVisibility(
            target: borderTarget,
            liveWindows: [WindowStackEntry(id: target, frame: CGRect(x: 13, y: 23, width: 296, height: 204))],
            frameTolerance: 2
        ) == .show)

        #expect(tiledBorderTargetVisibility(
            target: borderTarget,
            liveWindows: [WindowStackEntry(id: target, frame: CGRect(x: 80, y: 20, width: 300, height: 200))],
            frameTolerance: 2
        ) == .hideFrameMismatch(actual: CGRect(x: 80, y: 20, width: 300, height: 200)))

        #expect(tiledBorderTargetVisibility(
            target: borderTarget,
            liveWindows: [entry(51, x: 10, y: 20, width: 300, height: 200)]
        ) == .hideTargetMissing)
    }

    private func entry(
        _ raw: CGWindowID,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        ownerPID: ProcessID? = nil
    ) -> WindowStackEntry {
        WindowStackEntry(
            id: WindowID(raw: raw),
            frame: CGRect(x: x, y: y, width: width, height: height),
            ownerPID: ownerPID
        )
    }
}
