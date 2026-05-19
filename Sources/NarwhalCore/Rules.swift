public func matchRule(_ metadata: WindowMetadata, rules: [WindowRule]) -> RuleAction? {
    rules.first { rule in
        matches(rule.predicate, metadata: metadata)
    }?.action
}

public func windowOpenDecision(_ metadata: WindowMetadata, rules: [WindowRule]) -> WindowOpenDecision {
    guard let action = matchRule(metadata, rules: rules) else {
        return metadata.isResizable ? .tileOrFloatByDefault(metadata) : .forceFloat(metadata)
    }

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

private func matches(_ predicate: RulePredicate, metadata: WindowMetadata) -> Bool {
    switch predicate {
    case .bundleID(let expected):
        return metadata.bundleID.raw == expected
    case .bundleIDMatches(let regex):
        return matchesRegex(metadata.bundleID.raw, regex)
    case .role(let expected):
        return metadata.role == expected
    case .titleMatches(let regex):
        return matchesRegex(metadata.title, regex)
    case .and(let predicates):
        return predicates.allSatisfy { matches($0, metadata: metadata) }
    case .or(let predicates):
        return predicates.contains { matches($0, metadata: metadata) }
    case .not(let predicate):
        return !matches(predicate, metadata: metadata)
    }
}

private func matchesRegex(_ value: String, _ pattern: String) -> Bool {
    guard let regex = try? Regex(pattern) else { return false }
    return value.contains(regex)
}
