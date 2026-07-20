import AppKit
import NarwhalAppSupport
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("Workspace overview popover")
struct WorkspaceOverviewPopoverControllerTests {
    @Test("Overview reports active workspace health, counts, and focus in plain text")
    func activeWorkspaceRows() {
        let displayID = DisplayID(raw: 1)
        let spaceID = SpaceID(raw: 2)
        let windowID = WindowID(raw: 3)
        let key = WorkspaceKey(displayID: displayID, spaceID: spaceID)
        let workspace = WorkspacePresentation(
            key: key,
            displaySlot: 0,
            displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 760),
            tree: .leaf(windowID),
            windows: [WindowPresentation(
                id: windowID,
                title: "Editor",
                bundleID: BundleID(raw: "com.example.editor"),
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 1000, height: 760),
                workspaceKey: key,
                state: .tiled,
                isFocused: true,
                constraints: WindowConstraints(),
                ruleSource: .defaultBehavior
            )],
            health: .partialInventory(errorCount: 1),
            isActive: true
        )
        let controller = WorkspaceOverviewPopoverController(openWorkbench: {}, showMaintenance: { _ in })

        controller.update(WorkbenchPresentation(activeSpaceID: spaceID, workspaces: [workspace]))

        #expect(controller.debugRowTexts() == [
            "Display 0, Space 2, Partial inventory, 1 tiled, 0 floating, focus com.example.editor"
        ])
    }
}
