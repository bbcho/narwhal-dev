import AppKit
import NarwhalAppSupport
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("Layout workbench window")
struct LayoutWorkbenchControllerTests {
    @Test("Workbench enforces the visual contract at minimum size")
    func windowGeometry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-workbench-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = LayoutWorkbenchController(
            worldActor: WorldActor(),
            snapshotQuality: { .complete },
            applyPlan: { _, _ in true },
            activateManagedRules: { _ in },
            openAccessibilitySettings: {},
            namedLayoutsStore: NamedLayoutsStore(url: directory.appendingPathComponent("layouts.json")),
            managedRulesStore: ManagedRulesStore(url: directory.appendingPathComponent("rules.json"))
        )

        controller.show()
        let window = try #require(controller.debugWindow())
        window.setContentSize(CGSize(width: 860, height: 520))
        let metrics = try #require(controller.debugLayoutWidths())

        #expect(metrics.minimum == CGSize(width: 860, height: 520))
        #expect(metrics.rail == 172)
        #expect(metrics.inspector == 264)
        #expect(window.title == "Narwhal Layout Workbench")
        let inspector = try #require(controller.debugInspectorGeometry())
        #expect(inspector.hasVerticalScroller)
        #expect(inspector.contentHeight > inspector.viewportHeight)
        controller.close()
    }
}
