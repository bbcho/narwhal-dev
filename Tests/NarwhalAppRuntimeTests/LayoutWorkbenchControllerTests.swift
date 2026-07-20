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
        #expect(controller.debugRailHasVerticalScroller())
        let inspector = try #require(controller.debugInspectorGeometry())
        #expect(inspector.hasVerticalScroller)
        #expect(inspector.viewportHeight > 0)
        #expect(inspector.viewportHeight <= (window.contentView?.bounds.height ?? 0))
        #expect(inspector.contentHeight > 0)
        controller.close()
    }

    @Test("Workbench preserves active rules when the persisted artifact is malformed")
    func preservesActiveRulesAfterStoreRecovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-workbench-recovery-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rulesURL = directory.appendingPathComponent("rules.json")
        try Data("not-json".utf8).write(to: rulesURL)
        let activeRule = ManagedWindowRule(
            id: ManagedRuleID(rawValue: "editor"),
            name: "Editor",
            matcher: ManagedRuleMatcher(bundleID: "com.example.editor"),
            policy: ManagedRulePolicy()
        )
        let controller = LayoutWorkbenchController(
            worldActor: WorldActor(),
            snapshotQuality: { .complete },
            applyPlan: { _, _ in true },
            activateManagedRules: { _ in },
            managedRulesSnapshot: { [activeRule] },
            openAccessibilitySettings: {},
            namedLayoutsStore: NamedLayoutsStore(url: directory.appendingPathComponent("layouts.json")),
            managedRulesStore: ManagedRulesStore(url: rulesURL)
        )

        controller.show()

        #expect(controller.debugManagedRuleCount() == 1)
        #expect(!FileManager.default.fileExists(atPath: rulesURL.path))
        controller.close()
    }

    @Test("Managed rule list exposes current first-match counts")
    func managedRuleMatchCounts() {
        let rule = ManagedWindowRule(
            id: ManagedRuleID(rawValue: "editor"),
            name: "Editor",
            matcher: ManagedRuleMatcher(bundleID: "com.example.editor"),
            policy: ManagedRulePolicy()
        )
        let parent = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let editor = ManagedRulesEditorController(rules: [rule], matchCounts: [rule.id: 3]) { _ in }

        editor.beginSheet(for: parent)

        #expect(editor.debugRuleTitles() == ["1. Editor · 3 current"])
        parent.close()
    }

    @Test("Managed rule navigation stages valid edits and blocks invalid edits")
    func managedRuleNavigationPreservesEdits() {
        let first = ManagedWindowRule(
            id: ManagedRuleID(rawValue: "first"),
            name: "First",
            matcher: ManagedRuleMatcher(bundleID: "com.example.first"),
            policy: ManagedRulePolicy()
        )
        let second = ManagedWindowRule(
            id: ManagedRuleID(rawValue: "second"),
            name: "Second",
            matcher: ManagedRuleMatcher(bundleID: "com.example.second"),
            policy: ManagedRulePolicy()
        )
        let parent = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let editor = ManagedRulesEditorController(rules: [first, second]) { _ in }
        editor.beginSheet(for: parent)

        editor.debugEditName("Updated First")
        editor.debugSelectRule(at: 1)

        #expect(editor.debugRuleNames() == ["Updated First", "Second"])
        #expect(editor.debugSelectedIndex() == 1)

        editor.debugEditName("")
        editor.debugSelectRule(at: 0)

        #expect(editor.debugSelectedIndex() == 1)
        #expect(editor.debugRuleNames() == ["Updated First", "Second"])
        parent.close()
    }
}
