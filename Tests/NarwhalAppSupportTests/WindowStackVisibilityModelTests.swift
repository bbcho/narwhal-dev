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

    @Test("Missing target is explicit")
    func missingTargetIsExplicit() {
        #expect(windowStackVisibility(
            target: WindowID(raw: 40),
            frontToBackWindows: [entry(41, x: 0, y: 0, width: 300, height: 300)]
        ) == .targetMissing)
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
        height: CGFloat
    ) -> WindowStackEntry {
        WindowStackEntry(
            id: WindowID(raw: raw),
            frame: CGRect(x: x, y: y, width: width, height: height)
        )
    }
}
