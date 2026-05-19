import CoreGraphics
import Testing
@testable import WinMgrCore

@Suite("Window rules")
struct RulesTests {
    @Test("First matching rule wins")
    func firstMatchingRuleWins() {
        let finder = metadata(bundleID: "com.apple.finder", title: "Recents")
        let rules = [
            WindowRule(predicate: .bundleID("com.apple.finder"), action: .forceFloat),
            WindowRule(predicate: .titleMatches(regex: "Recents"), action: .ignore)
        ]

        #expect(matchRule(finder, rules: rules) == .forceFloat)
    }

    @Test("Predicates match exact fields, regex fields, composite branches, and negation")
    func predicatesMatchAllVariants() {
        let finder = metadata(bundleID: "com.apple.finder", title: "Recents", role: "AXWindow")
        let terminal = metadata(bundleID: "net.kovidgoyal.kitty", title: "swift test", role: "AXWindow")

        #expect(matchRule(finder, rules: [WindowRule(predicate: .bundleID("com.apple.finder"), action: .ignore)]) == .ignore)
        #expect(matchRule(finder, rules: [WindowRule(predicate: .bundleIDMatches(regex: "^com\\.apple\\."), action: .ignore)]) == .ignore)
        #expect(matchRule(finder, rules: [WindowRule(predicate: .role("AXWindow"), action: .ignore)]) == .ignore)
        #expect(matchRule(finder, rules: [WindowRule(predicate: .titleMatches(regex: "Recent[s]?"), action: .ignore)]) == .ignore)
        #expect(matchRule(finder, rules: [WindowRule(predicate: .and([.bundleIDMatches(regex: "^com\\.apple\\."), .role("AXWindow")]), action: .ignore)]) == .ignore)
        #expect(matchRule(finder, rules: [WindowRule(predicate: .or([.bundleID("no.match"), .titleMatches(regex: "Recents")]), action: .ignore)]) == .ignore)
        #expect(matchRule(terminal, rules: [WindowRule(predicate: .not(.bundleIDMatches(regex: "^com\\.apple\\.")), action: .ignore)]) == .ignore)
        #expect(matchRule(terminal, rules: [WindowRule(predicate: .and([.bundleIDMatches(regex: "^com\\.apple\\."), .role("AXWindow")]), action: .ignore)]) == nil)
    }

    @Test("Invalid programmatic regex predicates are total and do not match")
    func invalidRegexPredicateDoesNotMatch() {
        let finder = metadata(bundleID: "com.apple.finder", title: "Recents")

        #expect(matchRule(finder, rules: [
            WindowRule(predicate: .bundleIDMatches(regex: "["), action: .ignore),
            WindowRule(predicate: .titleMatches(regex: "("), action: .forceFloat)
        ]) == nil)
    }

    @Test("Window open decision maps rule actions and defaults exactly")
    func windowOpenDecisionMapsActionsAndDefaults() {
        let resizable = metadata(id: WindowID(raw: 1), bundleID: "com.apple.finder", isResizable: true)
        let fixed = metadata(id: WindowID(raw: 2), bundleID: "com.apple.finder", isResizable: false)

        #expect(windowOpenDecision(resizable, rules: []) == .tileOrFloatByDefault(resizable))
        #expect(windowOpenDecision(fixed, rules: []) == .forceFloat(fixed))
        #expect(windowOpenDecision(resizable, rules: [WindowRule(predicate: .bundleID("com.apple.finder"), action: .forceFloat)]) == .forceFloat(resizable))
        #expect(windowOpenDecision(resizable, rules: [WindowRule(predicate: .bundleID("com.apple.finder"), action: .ignore)]) == .ignore(resizable.id))
        #expect(windowOpenDecision(fixed, rules: [WindowRule(predicate: .bundleID("com.apple.finder"), action: .ignore)]) == .ignore(fixed.id))
        #expect(windowOpenDecision(resizable, rules: [WindowRule(predicate: .bundleID("com.apple.finder"), action: .pinToDisplay(slot: 2))]) == .pinToDisplay(resizable, slot: 2))
        #expect(windowOpenDecision(fixed, rules: [WindowRule(predicate: .bundleID("com.apple.finder"), action: .pinToDisplay(slot: 2))]) == .forceFloat(fixed))
        #expect(windowOpenDecision(resizable, rules: [WindowRule(predicate: .bundleID("com.apple.finder"), action: .tileToZone(ZoneID(raw: "center")))]) == .tileToZone(resizable, ZoneID(raw: "center")))
        #expect(windowOpenDecision(fixed, rules: [WindowRule(predicate: .bundleID("com.apple.finder"), action: .tileToZone(ZoneID(raw: "center")))]) == .forceFloat(fixed))
    }

    private func metadata(
        id: WindowID = WindowID(raw: 1),
        bundleID: String,
        title: String = "Window",
        role: String = "AXWindow",
        isResizable: Bool = true
    ) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: bundleID),
            title: title,
            role: role,
            pid: 42,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isResizable: isResizable,
            isMinimized: false
        )
    }
}
