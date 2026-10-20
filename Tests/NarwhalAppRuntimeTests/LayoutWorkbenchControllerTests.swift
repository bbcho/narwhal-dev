import AppKit
import NarwhalAppSupport
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("Layout workbench window")
struct LayoutWorkbenchControllerTests {
    @Test("Workbench renders scoped reconciliation status and recovery reason")
    func reconciliationStatus() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-workbench-reconciliation-test-\(UUID().uuidString)")
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
        let key = WorkspaceKey(displayID: DisplayID(raw: 1), spaceID: SpaceID(raw: 2))
        let issue = WorkspaceReconciliationIssue(
            operation: "Resize Right",
            windowIDs: [WindowID(raw: 3)],
            reason: "WindowServer frame remained stale"
        )
        let workspace = WorkspacePresentation(
            key: key,
            displaySlot: 0,
            displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 760),
            tree: .void,
            windows: [],
            health: .reconciliationRequired(issue),
            isActive: true
        )

        controller.show()
        controller.updatePresentationIfVisible(
            WorkbenchPresentation(activeSpaceID: key.spaceID, workspaces: [workspace])
        )

        #expect(controller.debugCanvasTitle().contains("Reconciliation required"))
        #expect(controller.debugRailToolTips() == [
            "Display 0, Space 2, Reconciliation required: Resize Right: WindowServer frame remained stale"
        ])
        controller.close()
    }

    @Test("A failed rule save re-activates the previous rules")
    func failedRuleSaveReactivatesPreviousRules() async throws {
        let blocked = try unwritableStoreDirectory()
        defer { try? FileManager.default.removeItem(at: blocked) }
        let activations = ActivationLog()
        let controller = workbench(store: ManagedRulesStore(url: blocked.appendingPathComponent("rules.json"))) { rules in
            activations.rules.append(rules)
        }
        let rule = sampleRule()

        await #expect(throws: (any Error).self) { try await controller.saveManagedRules([rule]) }

        #expect(activations.rules == [[rule], []])
    }

    @Test("When the previous rules cannot be re-activated either, the failure says both")
    func failedRollbackIsReported() async throws {
        let blocked = try unwritableStoreDirectory()
        defer { try? FileManager.default.removeItem(at: blocked) }
        let activations = ActivationLog()
        let controller = workbench(store: ManagedRulesStore(url: blocked.appendingPathComponent("rules.json"))) { rules in
            activations.rules.append(rules)
            if activations.rules.count == 2 { throw ManagedRuleValidationError.emptyName(index: 0) }
        }

        do {
            try await controller.saveManagedRules([sampleRule()])
            Issue.record("Expected the save to fail")
        } catch let error as ManagedRulesRollbackFailure {
            #expect(error.description.hasSuffix("so the new rules are active but not saved"))
        } catch {
            Issue.record("Expected a rollback failure, got \(error)")
        }
    }

    private final class ActivationLog {
        var rules: [[ManagedWindowRule]] = []
    }

    /// A regular file where the store expects its directory, so saving fails.
    private func unwritableStoreDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-blocked-\(UUID().uuidString)")
        try Data().write(to: url)
        return url
    }

    private func workbench(
        store: ManagedRulesStore,
        activate: @escaping LayoutWorkbenchController.ActivateManagedRules
    ) -> LayoutWorkbenchController {
        LayoutWorkbenchController(
            worldActor: WorldActor(),
            snapshotQuality: { .complete },
            applyPlan: { _, _ in true },
            activateManagedRules: activate,
            openAccessibilitySettings: {},
            namedLayoutsStore: NamedLayoutsStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("narwhal-layouts-\(UUID().uuidString).json")),
            managedRulesStore: store
        )
    }

    private func sampleRule() -> ManagedWindowRule {
        ManagedWindowRule(
            id: ManagedRuleID(rawValue: "terminal"),
            name: "Terminal",
            matcher: ManagedRuleMatcher(bundleID: "com.apple.Terminal"),
            policy: ManagedRulePolicy(placement: .forceFloat)
        )
    }

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
        let layoutsURL = directory.appendingPathComponent("layouts.json")
        try Data("not-json".utf8).write(to: rulesURL)
        try Data("not-json".utf8).write(to: layoutsURL)
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
            namedLayoutsStore: NamedLayoutsStore(url: layoutsURL),
            managedRulesStore: ManagedRulesStore(url: rulesURL)
        )

        controller.show()

        #expect(controller.debugManagedRuleCount() == 1)
        #expect(!FileManager.default.fileExists(atPath: rulesURL.path))
        let warning = try #require(controller.debugArtifactWarningText())
        #expect(warning.contains("named layouts JSON decode failed"))
        #expect(warning.contains("managed rules JSON decode failed"))
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
