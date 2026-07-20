import Foundation

public struct ManagedRuleID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ManagedRuleMatcher: Equatable, Codable, Sendable {
    public let bundleID: String?
    public let titleRegex: String?
    public let role: String?

    public init(bundleID: String? = nil, titleRegex: String? = nil, role: String? = nil) {
        self.bundleID = bundleID
        self.titleRegex = titleRegex
        self.role = role
    }
}

public enum ManagedRulePlacement: Equatable, Codable, Sendable {
    case defaultBehavior
    case forceFloat
    case ignore
    case displaySlot(Int)
    case zone(ZoneID)
}

public struct ManagedRulePolicy: Equatable, Codable, Sendable {
    public let placement: ManagedRulePlacement
    public let excludeFromFocusCycle: Bool
    public let minimumWidth: Double?
    public let minimumHeight: Double?

    public init(
        placement: ManagedRulePlacement = .defaultBehavior,
        excludeFromFocusCycle: Bool = false,
        minimumWidth: Double? = nil,
        minimumHeight: Double? = nil
    ) {
        self.placement = placement
        self.excludeFromFocusCycle = excludeFromFocusCycle
        self.minimumWidth = minimumWidth
        self.minimumHeight = minimumHeight
    }

    public var constraints: WindowConstraints {
        WindowConstraints(minWidth: minimumWidth, minHeight: minimumHeight)
    }
}

public struct ManagedWindowRule: Identifiable, Equatable, Codable, Sendable {
    public let id: ManagedRuleID
    public let name: String
    public let isEnabled: Bool
    public let matcher: ManagedRuleMatcher
    public let policy: ManagedRulePolicy

    public init(
        id: ManagedRuleID,
        name: String,
        isEnabled: Bool = true,
        matcher: ManagedRuleMatcher,
        policy: ManagedRulePolicy
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.matcher = matcher
        self.policy = policy
    }
}

public enum ManagedRuleValidationError: Error, Equatable, Sendable {
    case emptyID(index: Int)
    case duplicateID(ManagedRuleID)
    case emptyName(index: Int)
    case emptyMatcher(index: Int)
    case invalidTitleRegex(index: Int, pattern: String)
    case invalidDisplaySlot(index: Int, slot: Int)
    case emptyZone(index: Int)
    case invalidMinimumWidth(index: Int)
    case invalidMinimumHeight(index: Int)
}

public enum WindowRuleSource: Equatable, Sendable {
    case managed(id: ManagedRuleID, name: String)
    case lua(index: Int)
    case defaultBehavior
}

public struct WindowOpenResolution: Equatable, Sendable {
    public let decision: WindowOpenDecision
    public let source: WindowRuleSource

    public init(decision: WindowOpenDecision, source: WindowRuleSource) {
        self.decision = decision
        self.source = source
    }
}

public func validateManagedRules(
    _ rules: [ManagedWindowRule]
) -> Result<[ManagedWindowRule], ManagedRuleValidationError> {
    var ids = Set<ManagedRuleID>()
    for (index, rule) in rules.enumerated() {
        if trimmed(rule.id.rawValue).isEmpty {
            return .failure(.emptyID(index: index))
        }
        guard ids.insert(rule.id).inserted else {
            return .failure(.duplicateID(rule.id))
        }
        if trimmed(rule.name).isEmpty {
            return .failure(.emptyName(index: index))
        }

        let bundleID = normalized(rule.matcher.bundleID)
        let titleRegex = normalized(rule.matcher.titleRegex)
        let role = normalized(rule.matcher.role)
        if bundleID == nil, titleRegex == nil, role == nil {
            return .failure(.emptyMatcher(index: index))
        }
        if let titleRegex, (try? Regex(titleRegex)) == nil {
            return .failure(.invalidTitleRegex(index: index, pattern: titleRegex))
        }

        switch rule.policy.placement {
        case .displaySlot(let slot) where slot < 0:
            return .failure(.invalidDisplaySlot(index: index, slot: slot))
        case .zone(let zoneID) where trimmed(zoneID.raw).isEmpty:
            return .failure(.emptyZone(index: index))
        default:
            break
        }

        if !isValidMinimum(rule.policy.minimumWidth) {
            return .failure(.invalidMinimumWidth(index: index))
        }
        if !isValidMinimum(rule.policy.minimumHeight) {
            return .failure(.invalidMinimumHeight(index: index))
        }
    }
    return .success(rules)
}

public func firstMatchingManagedRule(
    _ metadata: WindowMetadata,
    rules: [ManagedWindowRule]
) -> ManagedWindowRule? {
    rules.first { rule in
        rule.isEnabled && managedRuleMatches(rule.matcher, metadata: metadata)
    }
}

public func resolveWindowOpen(
    _ metadata: WindowMetadata,
    managedRules: [ManagedWindowRule],
    luaRules: [WindowRule]
) -> WindowOpenResolution {
    if let rule = firstMatchingManagedRule(metadata, rules: managedRules) {
        return WindowOpenResolution(
            decision: decision(for: rule.policy.placement, metadata: metadata),
            source: .managed(id: rule.id, name: rule.name)
        )
    }

    if let match = luaRules.enumerated().first(where: { matches($0.element.predicate, metadata: metadata) }) {
        return WindowOpenResolution(
            decision: decision(for: match.element.action, metadata: metadata),
            source: .lua(index: match.offset)
        )
    }

    return WindowOpenResolution(
        decision: defaultDecision(for: metadata),
        source: .defaultBehavior
    )
}

public func managedConstraints(
    for metadata: WindowMetadata,
    rules: [ManagedWindowRule]
) -> WindowConstraints? {
    guard let constraints = firstMatchingManagedRule(metadata, rules: rules)?.policy.constraints,
          !constraints.isEmpty
    else { return nil }
    return constraints
}

public func isExcludedFromFocusCycle(
    _ metadata: WindowMetadata,
    rules: [ManagedWindowRule]
) -> Bool {
    firstMatchingManagedRule(metadata, rules: rules)?.policy.excludeFromFocusCycle == true
}

private func managedRuleMatches(_ matcher: ManagedRuleMatcher, metadata: WindowMetadata) -> Bool {
    if let bundleID = normalized(matcher.bundleID), metadata.bundleID.raw != bundleID {
        return false
    }
    if let role = normalized(matcher.role), metadata.role != role {
        return false
    }
    if let titleRegex = normalized(matcher.titleRegex) {
        guard let regex = try? Regex(titleRegex), metadata.title.contains(regex) else { return false }
    }
    return true
}

private func defaultDecision(for metadata: WindowMetadata) -> WindowOpenDecision {
    metadata.isResizable ? .tileOrFloatByDefault(metadata) : .forceFloat(metadata)
}

private func decision(for placement: ManagedRulePlacement, metadata: WindowMetadata) -> WindowOpenDecision {
    switch placement {
    case .defaultBehavior:
        return defaultDecision(for: metadata)
    case .forceFloat:
        return .forceFloat(metadata)
    case .ignore:
        return .ignore(metadata.id)
    case .displaySlot(let slot):
        return metadata.isResizable ? .pinToDisplay(metadata, slot: slot) : .forceFloat(metadata)
    case .zone(let zoneID):
        return metadata.isResizable ? .tileToZone(metadata, zoneID) : .forceFloat(metadata)
    }
}

private func decision(for action: RuleAction, metadata: WindowMetadata) -> WindowOpenDecision {
    switch action {
    case .forceFloat:
        return .forceFloat(metadata)
    case .ignore:
        return .ignore(metadata.id)
    case .pinToDisplay(let slot):
        return metadata.isResizable ? .pinToDisplay(metadata, slot: slot) : .forceFloat(metadata)
    case .tileToZone(let zoneID):
        return metadata.isResizable ? .tileToZone(metadata, zoneID) : .forceFloat(metadata)
    }
}

private func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmedValue = trimmed(value)
    return trimmedValue.isEmpty ? nil : trimmedValue
}

private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isValidMinimum(_ value: Double?) -> Bool {
    guard let value else { return true }
    return value.isFinite && value > 0
}
