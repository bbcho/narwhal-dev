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
