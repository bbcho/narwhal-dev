import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Window inventory polling")
struct WindowInventoryTests {
    @Test("First poll from empty state reports opened windows sorted by WindowID")
    func firstPollReportsOpenedWindowsInIDOrder() {
        let first = metadata(WindowID(raw: 1))
        let second = metadata(WindowID(raw: 2))

        let poll = pollWindowInventory(previous: .empty, current: [second, first])

        #expect(poll.state == WindowInventoryState(visibleWindowIDs: [first.id, second.id]))
        #expect(poll.events == [
            .windowOpened(first),
            .windowOpened(second)
        ])
    }

    @Test("Subsequent poll reports opened windows before closed windows with stable ordering")
    func subsequentPollReportsOpenedThenClosedWindows() {
        let staying = metadata(WindowID(raw: 3))
        let opened = metadata(WindowID(raw: 2))
        let previous = WindowInventoryState(visibleWindowIDs: [WindowID(raw: 1), staying.id])

        let poll = pollWindowInventory(previous: previous, current: [staying, opened])

        #expect(poll.state == WindowInventoryState(visibleWindowIDs: [opened.id, staying.id]))
        #expect(poll.events == [
            .windowOpened(opened),
            .windowClosed(WindowID(raw: 1))
        ])
    }

    @Test("Likely Space replacement diff becomes a baseline update instead of close-open events")
    func likelySpaceReplacementDiffBecomesBaselineUpdate() {
        let previous = WindowInventoryState(visibleWindowIDs: [
            WindowID(raw: 10),
            WindowID(raw: 11),
            WindowID(raw: 12)
        ])
        let current = [
            metadata(WindowID(raw: 20)),
            metadata(WindowID(raw: 21)),
            metadata(WindowID(raw: 22))
        ]

        let poll = pollWindowInventorySuppressingLikelySpaceReplacement(
            previous: previous,
            current: current
        )

        #expect(poll.state == WindowInventoryState(visibleWindowIDs: [
            WindowID(raw: 20),
            WindowID(raw: 21),
            WindowID(raw: 22)
        ]))
        #expect(poll.events == [])
        #expect(poll.suppressedSpaceReplacement)
    }

    @Test("Single open or close remains an inventory event")
    func singleOpenOrCloseRemainsInventoryEvent() {
        let staying = metadata(WindowID(raw: 3))
        let opened = metadata(WindowID(raw: 2))
        let previous = WindowInventoryState(visibleWindowIDs: [staying.id])

        let poll = pollWindowInventorySuppressingLikelySpaceReplacement(
            previous: previous,
            current: [staying, opened]
        )

        #expect(poll.events == [.windowOpened(opened)])
        #expect(!poll.suppressedSpaceReplacement)

        let singleClose = pollWindowInventorySuppressingLikelySpaceReplacement(
            previous: WindowInventoryState(visibleWindowIDs: [staying.id, WindowID(raw: 9)]),
            current: [staying]
        )
        #expect(singleClose.events == [.windowClosed(WindowID(raw: 9))])
        #expect(!singleClose.suppressedSpaceReplacement)
    }

    @Test("Mixed open-close inventory with overlap is still treated as Space replacement")
    func mixedOpenCloseInventoryWithOverlapIsSpaceReplacement() {
        let sticky = metadata(WindowID(raw: 1))
        let opened = metadata(WindowID(raw: 2))
        let previous = WindowInventoryState(visibleWindowIDs: [sticky.id, WindowID(raw: 3)])

        let poll = pollWindowInventorySuppressingLikelySpaceReplacement(
            previous: previous,
            current: [sticky, opened]
        )

        #expect(poll.state == WindowInventoryState(visibleWindowIDs: [sticky.id, opened.id]))
        #expect(poll.events == [])
        #expect(poll.suppressedSpaceReplacement)
    }

    @Test("Bulk close-only inventory collapse is treated as Space replacement")
    func bulkCloseOnlyInventoryCollapseIsSpaceReplacement() {
        let sticky = metadata(WindowID(raw: 1))
        let previous = WindowInventoryState(visibleWindowIDs: [
            sticky.id,
            WindowID(raw: 2),
            WindowID(raw: 3),
            WindowID(raw: 4)
        ])

        let poll = pollWindowInventorySuppressingLikelySpaceReplacement(
            previous: previous,
            current: [sticky]
        )

        #expect(poll.state == WindowInventoryState(visibleWindowIDs: [sticky.id]))
        #expect(poll.events == [])
        #expect(poll.suppressedSpaceReplacement)
    }

    @Test("Bulk open-only inventory expansion is treated as Space replacement")
    func bulkOpenOnlyInventoryExpansionIsSpaceReplacement() {
        let previous = WindowInventoryState(visibleWindowIDs: [
            WindowID(raw: 1),
            WindowID(raw: 2),
            WindowID(raw: 3),
            WindowID(raw: 4)
        ])
        let current = (1...17).map { metadata(WindowID(raw: UInt32($0))) }

        let poll = pollWindowInventorySuppressingLikelySpaceReplacement(
            previous: previous,
            current: current
        )

        #expect(poll.state == WindowInventoryState(visibleWindowIDs: Set(current.map(\.id))))
        #expect(poll.events == [])
        #expect(poll.suppressedSpaceReplacement)
    }

    @Test("Full disappearance inventory snapshot is treated as transient Space replacement")
    func fullDisappearanceInventorySnapshotIsTransientSpaceReplacement() {
        let previous = WindowInventoryState(visibleWindowIDs: [
            WindowID(raw: 10),
            WindowID(raw: 11)
        ])

        let poll = pollWindowInventorySuppressingLikelySpaceReplacement(
            previous: previous,
            current: []
        )

        #expect(poll.state == WindowInventoryState(visibleWindowIDs: []))
        #expect(poll.events == [])
        #expect(poll.suppressedSpaceReplacement)
    }

    @Test("Frame inventory reports non-focused window resize and move")
    func frameInventoryReportsNonFocusedWindowGeometryChanges() {
        let first = metadata(WindowID(raw: 10))
        let second = metadata(WindowID(raw: 20))
        let previous = WindowFrameInventoryState(framesByWindowID: [
            first.id: first.frame,
            second.id: second.frame
        ])
        let movedFirst = WindowMetadata(
            id: first.id,
            bundleID: first.bundleID,
            title: first.title,
            role: first.role,
            pid: first.pid,
            frame: first.frame.offsetBy(dx: 20, dy: 0),
            isResizable: true,
            isMinimized: false
        )
        let resizedSecond = WindowMetadata(
            id: second.id,
            bundleID: second.bundleID,
            title: second.title,
            role: second.role,
            pid: second.pid,
            frame: CGRect(x: second.frame.minX, y: second.frame.minY, width: 150, height: 125),
            isResizable: true,
            isMinimized: false
        )

        let poll = pollWindowFrameInventory(previous: previous, current: [resizedSecond, movedFirst], tolerance: 1)

        #expect(poll.events == [
            .windowMoved(first.id, movedFirst.frame),
            .windowResized(second.id, resizedSecond.frame.size)
        ])
        #expect(poll.state.framesByWindowID == [
            first.id: movedFirst.frame,
            second.id: resizedSecond.frame
        ])
    }

    @Test("Frame inventory reports edge resize with origin change as full-frame move")
    func frameInventoryReportsEdgeResizeWithOriginChangeAsFullFrameMove() {
        let window = metadata(WindowID(raw: 30))
        let previous = WindowFrameInventoryState(framesByWindowID: [
            window.id: window.frame
        ])
        let edgeResizedWindow = WindowMetadata(
            id: window.id,
            bundleID: window.bundleID,
            title: window.title,
            role: window.role,
            pid: window.pid,
            frame: CGRect(
                x: window.frame.minX - 40,
                y: window.frame.minY,
                width: window.frame.width + 40,
                height: window.frame.height
            ),
            isResizable: true,
            isMinimized: false
        )

        let poll = pollWindowFrameInventory(previous: previous, current: [edgeResizedWindow], tolerance: 1)

        #expect(poll.events == [
            .windowMoved(window.id, edgeResizedWindow.frame)
        ])
        #expect(poll.state.framesByWindowID == [
            window.id: edgeResizedWindow.frame
        ])
    }

    private func metadata(_ id: WindowID) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example.\(id.raw)"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: CGRect(x: Double(id.raw) * 10, y: 0, width: 100, height: 100),
            isResizable: true,
            isMinimized: false
        )
    }
}
