import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Directional focus navigation")
struct FocusNavigationTests {
    @Test("Directional focus chooses adjacent overlapping row or column before diagonal windows")
    func focusChoosesAdjacentOverlappingWindow() {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let d = WindowID(raw: 4)
        let layout = Layout(
            tiled: [
                a: CGRect(x: 0, y: 0, width: 100, height: 100),
                b: CGRect(x: 100, y: 0, width: 100, height: 100),
                c: CGRect(x: 0, y: 100, width: 100, height: 100),
                d: CGRect(x: 100, y: 100, width: 100, height: 100)
            ],
            floatingZOrder: [],
            hidden: []
        )

        #expect(focusTarget(in: layout, from: a, direction: .right) == b)
        #expect(focusTarget(in: layout, from: b, direction: .left) == a)
        #expect(focusTarget(in: layout, from: a, direction: .down) == c)
        #expect(focusTarget(in: layout, from: c, direction: .up) == a)
    }

    @Test("Directional focus can fall back to diagonal candidate when no row candidate exists")
    func focusFallsBackToDiagonalCandidate() {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let layout = Layout(
            tiled: [
                a: CGRect(x: 0, y: 0, width: 100, height: 100),
                b: CGRect(x: 200, y: 140, width: 100, height: 100),
                c: CGRect(x: 400, y: 500, width: 100, height: 100)
            ],
            floatingZOrder: [],
            hidden: []
        )

        #expect(focusTarget(in: layout, from: a, direction: .right) == b)
    }

    @Test("Directional focus returns nil when source is absent or no candidate exists")
    func focusReturnsNilWithoutSourceOrCandidate() {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let layout = Layout(
            tiled: [a: CGRect(x: 0, y: 0, width: 100, height: 100)],
            floatingZOrder: [b],
            hidden: []
        )

        #expect(focusTarget(in: layout, from: a, direction: .left) == nil)
        #expect(focusTarget(in: layout, from: b, direction: .right) == nil)
    }

    @Test("Directional focus can use observed window frames outside the tiled layout")
    func focusUsesObservedFramesOutsideTiledLayout() {
        let a = metadata(id: 1, x: 0, y: 0, title: "A")
        let b = metadata(id: 2, x: 300, y: 0, title: "B")
        let c = metadata(id: 3, x: 0, y: 300, title: "C")

        #expect(focusTarget(windows: [c, b, a], from: a.id, direction: .right) == b.id)
        #expect(focusTarget(windows: [c, b, a], from: a.id, direction: .down) == c.id)
    }

    @Test("Focus cycling walks visible windows by frame order and wraps")
    func focusCycleWalksVisibleWindowsByFrameOrder() {
        let topLeft = metadata(id: 1, x: 0, y: 0, title: "A")
        let topRight = metadata(id: 2, x: 300, y: 0, title: "B")
        let bottomLeft = metadata(id: 3, x: 0, y: 300, title: "C")
        let minimized = WindowMetadata(
            id: WindowID(raw: 4),
            bundleID: BundleID(raw: "com.example"),
            title: "D",
            role: "AXWindow",
            pid: 4,
            frame: CGRect(x: 600, y: 0, width: 100, height: 100),
            isResizable: true,
            isMinimized: true
        )
        let windows = [bottomLeft, minimized, topRight, topLeft]

        #expect(focusCycleTarget(windows: windows, from: nil, direction: .next) == topLeft.id)
        #expect(focusCycleTarget(windows: windows, from: nil, direction: .previous) == bottomLeft.id)
        #expect(focusCycleTarget(windows: windows, from: topLeft.id, direction: .next) == topRight.id)
        #expect(focusCycleTarget(windows: windows, from: topRight.id, direction: .next) == bottomLeft.id)
        #expect(focusCycleTarget(windows: windows, from: bottomLeft.id, direction: .next) == topLeft.id)
        #expect(focusCycleTarget(windows: windows, from: topLeft.id, direction: .previous) == bottomLeft.id)
    }

    @Test("Focus cycle candidates keep walking after the first target")
    func focusCycleCandidatesKeepWalkingAfterFirstTarget() {
        let topLeft = metadata(id: 1, x: 0, y: 0, title: "A")
        let topRight = metadata(id: 2, x: 300, y: 0, title: "B")
        let bottomLeft = metadata(id: 3, x: 0, y: 300, title: "C")

        #expect(focusCycleCandidates(
            windows: [bottomLeft, topRight, topLeft],
            from: topLeft.id,
            direction: .next
        ) == [topRight.id, bottomLeft.id, topLeft.id])
        #expect(focusCycleCandidates(
            windows: [bottomLeft, topRight, topLeft],
            from: topLeft.id,
            direction: .previous
        ) == [bottomLeft.id, topRight.id, topLeft.id])
    }

    private func metadata(id: CGWindowID, x: CGFloat, y: CGFloat, title: String) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: id),
            bundleID: BundleID(raw: "com.example"),
            title: title,
            role: "AXWindow",
            pid: Int32(id),
            frame: CGRect(x: x, y: y, width: 100, height: 100),
            isResizable: true,
            isMinimized: false
        )
    }
}
