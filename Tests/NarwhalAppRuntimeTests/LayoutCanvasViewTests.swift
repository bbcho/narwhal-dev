import AppKit
import NarwhalAppSupport
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("Layout canvas geometry")
struct LayoutCanvasViewTests {
    @Test("Actual, preview, and empty tree geometry share one fitted display transform")
    func geometryUsesOneTransform() throws {
        let displayID = DisplayID(raw: 1)
        let spaceID = SpaceID(raw: 2)
        let windowID = WindowID(raw: 3)
        let split = try Split.create(axis: .horizontal, cells: [
            try Cell.create(weight: 1, node: .leaf(windowID)).get(),
            try Cell.create(weight: 1, node: .void).get()
        ]).get()
        let workspace = WorkspacePresentation(
            key: WorkspaceKey(displayID: displayID, spaceID: spaceID),
            displaySlot: 0,
            displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            tree: .split(split),
            windows: [WindowPresentation(
                id: windowID,
                title: "Editor",
                bundleID: BundleID(raw: "com.example.editor"),
                role: "AXWindow",
                frame: CGRect(x: 0, y: 0, width: 500, height: 800),
                workspaceKey: WorkspaceKey(displayID: displayID, spaceID: spaceID),
                state: .tiled,
                isFocused: true,
                constraints: WindowConstraints(),
                ruleSource: .defaultBehavior
            )],
            health: .ready,
            isActive: true
        )
        let view = LayoutCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.workspace = workspace
        view.preview = CommandPreview(
            operation: .resize(.right),
            spaceID: spaceID,
            changes: [],
            proposedLayout: Layout(
                tiled: [windowID: CGRect(x: 0, y: 0, width: 700, height: 800)],
                floatingZOrder: [],
                hidden: []
            )
        )

        let geometry = view.geometrySnapshot()

        #expect(geometry.displayRect == CGRect(x: 80, y: 24, width: 440, height: 352))
        #expect(geometry.windowRects[windowID] == CGRect(x: 80, y: 24, width: 220, height: 352))
        #expect(geometry.previewRects[windowID] == CGRect(x: 80, y: 24, width: 308, height: 352))
        #expect(geometry.emptyRects == [CGRect(x: 300, y: 24, width: 220, height: 352)])
    }

    @Test("Canvas reports selection without changing a focus field")
    func selectionIsIndependent() {
        let view = LayoutCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(view.accessibilityLabel() == "Layout geometry canvas")
        #expect(view.selectedWindowID == nil)
    }
}
