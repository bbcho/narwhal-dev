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
