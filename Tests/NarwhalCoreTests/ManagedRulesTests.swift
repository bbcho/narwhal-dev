import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Managed window rules")
struct ManagedRulesTests {
    @Test("First enabled managed rule wins before Lua")
    func managedRulesHaveTransparentPrecedence() throws {
        let window = metadata(bundleID: "com.example.Editor", title: "Preferences")
        let disabled = rule(
            id: "disabled",
            name: "Disabled",
            isEnabled: false,
            matcher: ManagedRuleMatcher(bundleID: window.bundleID.raw),
            placement: .ignore
        )
        let managed = rule(
            id: "preferences",
            name: "Float preferences",
            matcher: ManagedRuleMatcher(bundleID: window.bundleID.raw, titleRegex: "Preferences$"),
            placement: .forceFloat
        )
        let lua = WindowRule(predicate: .bundleID(window.bundleID.raw), action: .ignore)

        let resolution = resolveWindowOpen(
            window,
            managedRules: [disabled, managed],
            luaRules: [lua]
        )

        #expect(resolution.decision == .forceFloat(window))
        #expect(resolution.source == .managed(id: managed.id, name: managed.name))
    }

    @Test("Managed default placement intentionally prevents a Lua placement override")
    func managedDefaultPlacementWins() {
        let window = metadata(bundleID: "com.example.Editor")
        let managed = rule(
            id: "constraints-only",
            name: "Editor geometry",
            matcher: ManagedRuleMatcher(bundleID: window.bundleID.raw),
            placement: .defaultBehavior
        )

        let resolution = resolveWindowOpen(
            window,
            managedRules: [managed],
            luaRules: [WindowRule(predicate: .bundleID(window.bundleID.raw), action: .ignore)]
        )

        #expect(resolution.decision == .tileOrFloatByDefault(window))
        #expect(resolution.source == .managed(id: managed.id, name: managed.name))
    }

    @Test("Matcher fields compose with AND semantics")
    func matcherFieldsCompose() {
        let matcher = ManagedRuleMatcher(
            bundleID: "com.example.Editor",
            titleRegex: "^Project [0-9]+$",
            role: "AXWindow"
        )
        let managed = rule(id: "project", name: "Project", matcher: matcher, placement: .forceFloat)

        #expect(firstMatchingManagedRule(metadata(bundleID: "com.example.Editor", title: "Project 42"), rules: [managed]) == managed)
        #expect(firstMatchingManagedRule(metadata(bundleID: "com.example.Editor", title: "Preferences"), rules: [managed]) == nil)
        #expect(firstMatchingManagedRule(metadata(bundleID: "com.example.Other", title: "Project 42"), rules: [managed]) == nil)
    }

    @Test("Validation rejects ambiguous, malformed, and duplicate rules")
    func validationRejectsInvalidRules() {
        let empty = rule(id: "empty", name: "Empty", matcher: ManagedRuleMatcher(), placement: .forceFloat)
        #expect(validateManagedRules([empty]) == .failure(.emptyMatcher(index: 0)))

        let regex = rule(
            id: "regex",
            name: "Regex",
            matcher: ManagedRuleMatcher(titleRegex: "["),
            placement: .forceFloat
        )
        #expect(validateManagedRules([regex]) == .failure(.invalidTitleRegex(index: 0, pattern: "[")))

        let duplicateA = rule(
            id: "same",
            name: "First",
            matcher: ManagedRuleMatcher(bundleID: "a"),
            placement: .forceFloat
        )
        let duplicateB = rule(
            id: "same",
            name: "Second",
            matcher: ManagedRuleMatcher(bundleID: "b"),
            placement: .ignore
        )
        #expect(validateManagedRules([duplicateA, duplicateB]) == .failure(.duplicateID(duplicateA.id)))
    }

    @Test("Managed policies expose focus and minimum-size behavior")
    func auxiliaryPoliciesAreResolvedFromFirstMatch() {
        let window = metadata(bundleID: "com.example.Editor")
        let managed = ManagedWindowRule(
            id: ManagedRuleID(rawValue: "editor"),
            name: "Editor",
            matcher: ManagedRuleMatcher(bundleID: window.bundleID.raw),
            policy: ManagedRulePolicy(
                excludeFromFocusCycle: true,
                minimumWidth: 720,
                minimumHeight: 480
            )
        )

        #expect(isExcludedFromFocusCycle(window, rules: [managed]))
        #expect(managedConstraints(for: window, rules: [managed]) == WindowConstraints(minWidth: 720, minHeight: 480))
    }

    private func rule(
        id: String,
        name: String,
        isEnabled: Bool = true,
        matcher: ManagedRuleMatcher,
        placement: ManagedRulePlacement
    ) -> ManagedWindowRule {
        ManagedWindowRule(
            id: ManagedRuleID(rawValue: id),
            name: name,
            isEnabled: isEnabled,
            matcher: matcher,
            policy: ManagedRulePolicy(placement: placement)
        )
    }

    private func metadata(
        bundleID: String,
        title: String = "Window",
        role: String = "AXWindow"
    ) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: 1),
            bundleID: BundleID(raw: bundleID),
            title: title,
            role: role,
            pid: 42,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 700),
            isResizable: true,
            isMinimized: false
        )
    }
}
