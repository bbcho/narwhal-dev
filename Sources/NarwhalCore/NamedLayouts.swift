import Foundation

public struct NamedLayoutID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct LayoutSlotID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum LayoutTitleMatcher: Equatable, Codable, Sendable {
    case exact(String)
    case regex(String)
}

public struct LayoutWindowMatcher: Equatable, Codable, Sendable {
    public let bundleID: String
    public let role: String?
    public let title: LayoutTitleMatcher?

    public init(bundleID: String, role: String? = nil, title: LayoutTitleMatcher? = nil) {
        self.bundleID = bundleID
        self.role = role
        self.title = title
    }
}

public struct LayoutTemplateSlot: Equatable, Codable, Sendable {
    public let id: LayoutSlotID
    public let matcher: LayoutWindowMatcher

    public init(id: LayoutSlotID, matcher: LayoutWindowMatcher) {
        self.id = id
        self.matcher = matcher
    }
}

public struct LayoutTemplateCell: Equatable, Codable, Sendable {
    public let weight: Double
    public let node: LayoutTemplateNode

    public init(weight: Double, node: LayoutTemplateNode) {
        self.weight = weight
        self.node = node
    }
}

public indirect enum LayoutTemplateNode: Equatable, Codable, Sendable {
    case empty
    case slot(LayoutTemplateSlot)
    case split(axis: Axis, cells: [LayoutTemplateCell])
}

public struct DisplayLayoutTemplate: Equatable, Codable, Sendable {
    public let displaySlot: Int
    public let root: LayoutTemplateNode

    public init(displaySlot: Int, root: LayoutTemplateNode) {
        self.displaySlot = displaySlot
        self.root = root
    }
}

public struct NamedLayout: Identifiable, Equatable, Codable, Sendable {
    public let id: NamedLayoutID
    public let name: String
    public let revision: Int
    public let displays: [DisplayLayoutTemplate]

    public init(id: NamedLayoutID, name: String, revision: Int = 1, displays: [DisplayLayoutTemplate]) {
        self.id = id
        self.name = name
        self.revision = revision
        self.displays = displays
    }
}

public struct NamedLayoutCandidate: Equatable, Sendable {
    public let window: WindowMetadata
    public let currentDisplaySlot: Int?

    public init(window: WindowMetadata, currentDisplaySlot: Int?) {
        self.window = window
        self.currentDisplaySlot = currentDisplaySlot
    }
}

public struct MatchedLayoutSlot: Equatable, Sendable {
    public let slotID: LayoutSlotID
    public let windowID: WindowID
    public let targetDisplaySlot: Int

    public init(slotID: LayoutSlotID, windowID: WindowID, targetDisplaySlot: Int) {
        self.slotID = slotID
        self.windowID = windowID
        self.targetDisplaySlot = targetDisplaySlot
    }
}

public struct UnmatchedLayoutSlot: Equatable, Sendable {
    public let slotID: LayoutSlotID
    public let targetDisplaySlot: Int
    public let matcher: LayoutWindowMatcher

    public init(slotID: LayoutSlotID, targetDisplaySlot: Int, matcher: LayoutWindowMatcher) {
        self.slotID = slotID
        self.targetDisplaySlot = targetDisplaySlot
        self.matcher = matcher
    }
}

public struct NamedLayoutMatchResult: Equatable, Sendable {
    public let matches: [MatchedLayoutSlot]
    public let unmatchedSlots: [UnmatchedLayoutSlot]
    public let unmatchedWindows: [WindowID]
    public let missingDisplaySlots: [Int]

    public init(
        matches: [MatchedLayoutSlot],
        unmatchedSlots: [UnmatchedLayoutSlot],
        unmatchedWindows: [WindowID],
        missingDisplaySlots: [Int]
    ) {
        self.matches = matches
        self.unmatchedSlots = unmatchedSlots
        self.unmatchedWindows = unmatchedWindows
        self.missingDisplaySlots = missingDisplaySlots
    }

    public var isComplete: Bool {
        unmatchedSlots.isEmpty && missingDisplaySlots.isEmpty
    }
}

public enum NamedLayoutValidationError: Error, Equatable, Sendable {
    case emptyID
    case emptyName
    case invalidRevision(Int)
    case emptyDisplays
    case duplicateDisplaySlot(Int)
    case invalidDisplaySlot(Int)
    case duplicateSlotID(LayoutSlotID)
    case emptySlotID
    case emptyBundleID(LayoutSlotID)
    case invalidTitleRegex(slot: LayoutSlotID, pattern: String)
    case stringTooLong(field: String, limit: Int)
    case invalidCellCount(displaySlot: Int, count: Int)
    case invalidWeight(displaySlot: Int)
    case templateTooDeep(displaySlot: Int, limit: Int)
    case tooManySlots(found: Int, limit: Int)
}

public let namedLayoutMaximumStringLength = 512
public let namedLayoutMaximumSlots = 64
public let namedLayoutMaximumDepth = 12

public func validateNamedLayout(_ layout: NamedLayout) -> Result<NamedLayout, NamedLayoutValidationError> {
    guard !layout.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .failure(.emptyID)
    }
    guard !layout.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .failure(.emptyName)
    }
    guard layout.id.rawValue.count <= namedLayoutMaximumStringLength else {
        return .failure(.stringTooLong(field: "id", limit: namedLayoutMaximumStringLength))
    }
    guard layout.name.count <= namedLayoutMaximumStringLength else {
        return .failure(.stringTooLong(field: "name", limit: namedLayoutMaximumStringLength))
    }
    guard layout.revision > 0 else { return .failure(.invalidRevision(layout.revision)) }
    guard !layout.displays.isEmpty else { return .failure(.emptyDisplays) }

    var displaySlots = Set<Int>()
    var slotIDs = Set<LayoutSlotID>()
    var slotCount = 0
    for display in layout.displays {
        guard display.displaySlot >= 0 else { return .failure(.invalidDisplaySlot(display.displaySlot)) }
        guard displaySlots.insert(display.displaySlot).inserted else {
            return .failure(.duplicateDisplaySlot(display.displaySlot))
        }
        if let error = validateTemplateNode(
            display.root,
            displaySlot: display.displaySlot,
            depth: 1,
            slotIDs: &slotIDs,
            slotCount: &slotCount
        ) {
            return .failure(error)
        }
    }
    guard slotCount <= namedLayoutMaximumSlots else {
        return .failure(.tooManySlots(found: slotCount, limit: namedLayoutMaximumSlots))
    }
    return .success(layout)
}

public func matchNamedLayout(
    _ layout: NamedLayout,
    candidates: [NamedLayoutCandidate],
    availableDisplaySlots: Set<Int>
) -> Result<NamedLayoutMatchResult, NamedLayoutValidationError> {
    switch validateNamedLayout(layout) {
    case .failure(let error):
        return .failure(error)
    case .success:
        break
    }

    let orderedCandidates = candidates.sorted(by: candidateScreenOrder)
    var unassigned = Set(orderedCandidates.map(\.window.id))
    var matches: [MatchedLayoutSlot] = []
    var unmatchedSlots: [UnmatchedLayoutSlot] = []
    let orderedDisplays = layout.displays.sorted { $0.displaySlot < $1.displaySlot }

    for display in orderedDisplays where availableDisplaySlots.contains(display.displaySlot) {
        for slot in templateSlots(in: display.root) {
            let candidate = orderedCandidates
                .filter { unassigned.contains($0.window.id) && layoutMatcher(slot.matcher, matches: $0.window) }
                .sorted { lhs, rhs in
                    let lhsOnTarget = lhs.currentDisplaySlot == display.displaySlot
                    let rhsOnTarget = rhs.currentDisplaySlot == display.displaySlot
                    if lhsOnTarget != rhsOnTarget { return lhsOnTarget }
                    return candidateScreenOrder(lhs, rhs)
                }
                .first
            if let candidate {
                unassigned.remove(candidate.window.id)
                matches.append(MatchedLayoutSlot(
                    slotID: slot.id,
                    windowID: candidate.window.id,
                    targetDisplaySlot: display.displaySlot
                ))
            } else {
                unmatchedSlots.append(UnmatchedLayoutSlot(
                    slotID: slot.id,
                    targetDisplaySlot: display.displaySlot,
                    matcher: slot.matcher
                ))
            }
        }
    }

    return .success(NamedLayoutMatchResult(
        matches: matches,
        unmatchedSlots: unmatchedSlots,
        unmatchedWindows: orderedCandidates.map(\.window.id).filter(unassigned.contains),
        missingDisplaySlots: orderedDisplays.map(\.displaySlot).filter { !availableDisplaySlots.contains($0) }
    ))
}

public func resolvedTemplateNode(
    _ node: LayoutTemplateNode,
    assignments: [LayoutSlotID: WindowID]
) -> Node {
    switch node {
    case .empty:
        return .void
    case .slot(let slot):
        return assignments[slot.id].map(Node.leaf) ?? .void
    case .split(let axis, let cells):
        let resolvedCells = cells.compactMap { cell -> Cell? in
            let child = resolvedTemplateNode(cell.node, assignments: assignments)
            guard child != .void else { return nil }
            return try? Cell.create(weight: cell.weight, node: child).get()
        }
        guard resolvedCells.count >= 2,
              let split = try? Split.create(axis: axis, cells: resolvedCells).get()
        else {
            return resolvedCells.first?.node ?? .void
        }
        return .split(split)
    }
}

private func validateTemplateNode(
    _ node: LayoutTemplateNode,
    displaySlot: Int,
    depth: Int,
    slotIDs: inout Set<LayoutSlotID>,
    slotCount: inout Int
) -> NamedLayoutValidationError? {
    guard depth <= namedLayoutMaximumDepth else {
        return .templateTooDeep(displaySlot: displaySlot, limit: namedLayoutMaximumDepth)
    }
    switch node {
    case .empty:
        return nil
    case .slot(let slot):
        slotCount += 1
        guard slotCount <= namedLayoutMaximumSlots else {
            return .tooManySlots(found: slotCount, limit: namedLayoutMaximumSlots)
        }
        guard !slot.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .emptySlotID
        }
        guard slot.id.rawValue.count <= namedLayoutMaximumStringLength else {
            return .stringTooLong(field: "slot.id", limit: namedLayoutMaximumStringLength)
        }
        guard slotIDs.insert(slot.id).inserted else { return .duplicateSlotID(slot.id) }
        guard !slot.matcher.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .emptyBundleID(slot.id)
        }
        guard slot.matcher.bundleID.count <= namedLayoutMaximumStringLength else {
            return .stringTooLong(field: "slot.bundleID", limit: namedLayoutMaximumStringLength)
        }
        if let role = slot.matcher.role, role.count > namedLayoutMaximumStringLength {
            return .stringTooLong(field: "slot.role", limit: namedLayoutMaximumStringLength)
        }
        if let title = slot.matcher.title {
            let value: String
            switch title {
            case .exact(let exact):
                value = exact
            case .regex(let pattern):
                value = pattern
                if (try? Regex(pattern)) == nil {
                    return .invalidTitleRegex(slot: slot.id, pattern: pattern)
                }
            }
            if value.count > namedLayoutMaximumStringLength {
                return .stringTooLong(field: "slot.title", limit: namedLayoutMaximumStringLength)
            }
        }
        return nil
    case .split(_, let cells):
        guard cells.count >= 2 else {
            return .invalidCellCount(displaySlot: displaySlot, count: cells.count)
        }
        guard cells.allSatisfy({ $0.weight.isFinite && $0.weight > 0 }) else {
            return .invalidWeight(displaySlot: displaySlot)
        }
        for cell in cells {
            if let error = validateTemplateNode(
                cell.node,
                displaySlot: displaySlot,
                depth: depth + 1,
                slotIDs: &slotIDs,
                slotCount: &slotCount
            ) {
                return error
            }
        }
        return nil
    }
}

private func templateSlots(in node: LayoutTemplateNode) -> [LayoutTemplateSlot] {
    switch node {
    case .empty:
        return []
    case .slot(let slot):
        return [slot]
    case .split(_, let cells):
        return cells.flatMap { templateSlots(in: $0.node) }
    }
}

private func layoutMatcher(_ matcher: LayoutWindowMatcher, matches window: WindowMetadata) -> Bool {
    guard window.bundleID.raw == matcher.bundleID else { return false }
    if let role = matcher.role, window.role != role { return false }
    switch matcher.title {
    case nil:
        return true
    case .exact(let title):
        return window.title == title
    case .regex(let pattern):
        guard let regex = try? Regex(pattern) else { return false }
        return window.title.contains(regex)
    }
}

private func candidateScreenOrder(_ lhs: NamedLayoutCandidate, _ rhs: NamedLayoutCandidate) -> Bool {
    let lhsFrame = lhs.window.frame.standardized
    let rhsFrame = rhs.window.frame.standardized
    if lhsFrame.minY != rhsFrame.minY { return lhsFrame.minY < rhsFrame.minY }
    if lhsFrame.minX != rhsFrame.minX { return lhsFrame.minX < rhsFrame.minX }
    if lhs.window.bundleID.raw != rhs.window.bundleID.raw {
        return lhs.window.bundleID.raw < rhs.window.bundleID.raw
    }
    if lhs.window.title != rhs.window.title { return lhs.window.title < rhs.window.title }
    return lhs.window.id.raw < rhs.window.id.raw
}
