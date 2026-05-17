import CoreGraphics

public struct StoredWindowRef: Hashable, Codable, Sendable {
    public let bundleID: BundleID
    public let title: String
    public let role: String
    public let occurrence: Int
    public let lastKnownFrame: CGRect?

    public init(
        bundleID: BundleID,
        title: String,
        role: String,
        occurrence: Int,
        lastKnownFrame: CGRect?
    ) {
        self.bundleID = bundleID
        self.title = title
        self.role = role
        self.occurrence = occurrence
        self.lastKnownFrame = lastKnownFrame
    }
}

public indirect enum StoredNode: Equatable, Codable, Sendable {
    case void
    case leaf(StoredWindowRef)
    case split(StoredSplit)
}

public struct StoredSplit: Equatable, Codable, Sendable {
    public let axis: Axis
    public let cells: [StoredCell]

    private init(axis: Axis, cells: [StoredCell]) {
        self.axis = axis
        self.cells = cells
    }

    public static func create(axis: Axis, cells: [StoredCell]) -> Result<StoredSplit, InvariantError> {
        guard cells.count >= 2 else { return .failure(.splitNeedsAtLeastTwoCells) }
        guard cells.allSatisfy({ $0.weight.isFinite }) else {
            return .failure(.nonFiniteNumber("storedCell.weight"))
        }
        return .success(StoredSplit(axis: axis, cells: cells))
    }

    private enum CodingKeys: String, CodingKey {
        case axis
        case cells
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let axis = try container.decode(Axis.self, forKey: .axis)
        let cells = try container.decode([StoredCell].self, forKey: .cells)
        switch StoredSplit.create(axis: axis, cells: cells) {
        case .success(let split):
            self = split
        case .failure(let error):
            throw DecodingError.dataCorruptedError(
                forKey: .cells,
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }
}

public struct StoredCell: Equatable, Codable, Sendable {
    public let weight: Double
    public let node: StoredNode

    private init(weight: Double, node: StoredNode) {
        self.weight = weight
        self.node = node
    }

    public static func create(weight: Double, node: StoredNode) -> Result<StoredCell, InvariantError> {
        guard weight.isFinite else { return .failure(.nonFiniteNumber("storedCell.weight")) }
        guard weight > 0 else { return .failure(.cellWeightMustBePositive) }
        return .success(StoredCell(weight: weight, node: node))
    }

    private enum CodingKeys: String, CodingKey {
        case weight
        case node
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let weight = try container.decode(Double.self, forKey: .weight)
        let node = try container.decode(StoredNode.self, forKey: .node)
        switch StoredCell.create(weight: weight, node: node) {
        case .success(let cell):
            self = cell
        case .failure(let error):
            throw DecodingError.dataCorruptedError(
                forKey: .weight,
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }
}

public struct StoredDisplayLayout: Equatable, Codable, Sendable {
    public let displaySlot: Int
    public let displayFingerprint: String?
    public let tree: StoredNode
    public let floating: [StoredWindowRef]

    public init(displaySlot: Int, displayFingerprint: String?, tree: StoredNode, floating: [StoredWindowRef]) {
        self.displaySlot = displaySlot
        self.displayFingerprint = displayFingerprint
        self.tree = tree
        self.floating = floating
    }
}

public struct StoredSpace: Equatable, Codable, Sendable {
    public let layouts: [StoredDisplayLayout]
    public let focused: StoredWindowRef?

    public init(layouts: [StoredDisplayLayout], focused: StoredWindowRef?) {
        self.layouts = layouts
        self.focused = focused
    }
}

public struct StoredPendingRule: Equatable, Codable, Sendable {
    public let window: StoredWindowRef
    public let action: StoredRuleAction

    public init(window: StoredWindowRef, action: StoredRuleAction) {
        self.window = window
        self.action = action
    }
}

public enum StoredRuleAction: Equatable, Codable, Sendable {
    case forceFloat
    case ignore
    case pinToDisplay(displaySlot: Int)
}

public struct StoredWorld: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let empty = StoredWorld(schemaVersion: currentSchemaVersion, activeSpace: nil, pendingRules: [])

    public let schemaVersion: Int
    public let activeSpace: StoredSpace?
    public let pendingRules: [StoredPendingRule]

    public init(schemaVersion: Int, activeSpace: StoredSpace?, pendingRules: [StoredPendingRule]) {
        self.schemaVersion = schemaVersion
        self.activeSpace = activeSpace
        self.pendingRules = pendingRules
    }
}

public func validateStoredWorld(_ stored: StoredWorld) -> Result<StoredWorld, RestoreError> {
    guard stored.schemaVersion == StoredWorld.currentSchemaVersion else {
        return .failure(.invalidStoredWorld("unsupported schemaVersion \(stored.schemaVersion)"))
    }

    for ref in stored.allWindowRefs {
        guard ref.occurrence >= 0 else {
            return .failure(.invalidStoredWorld("StoredWindowRef.occurrence must be non-negative"))
        }
        if let frame = ref.lastKnownFrame, frame.hasNonFiniteCoordinate {
            return .failure(.invalidStoredWorld("StoredWindowRef.lastKnownFrame must be finite"))
        }
    }

    return .success(stored)
}

public func storedWorld(from world: World) -> StoredWorld {
    guard let activeSpaceID = world.activeSpace,
          let activeSpace = world.spaces[activeSpaceID]
    else {
        return .empty
    }

    let refByWindowID = storedRefsByWindowID(for: world.windows)
    let layouts = activeSpace.displays.compactMap { displayID, displayState -> StoredDisplayLayout? in
        guard let display = world.displays[displayID] else { return nil }
        return StoredDisplayLayout(
            displaySlot: display.slot,
            displayFingerprint: display.fingerprint,
            tree: storedNode(from: displayState.tree, refs: refByWindowID),
            floating: displayState.floating.compactMap { refByWindowID[$0] }
        )
    }.sorted { lhs, rhs in
        if lhs.displaySlot == rhs.displaySlot {
            return (lhs.displayFingerprint ?? "") < (rhs.displayFingerprint ?? "")
        }
        return lhs.displaySlot < rhs.displaySlot
    }

    let focused = activeSpace.focused.flatMap { refByWindowID[$0] }
    let pendingRules = world.pendingRules.compactMap { windowID, action -> StoredPendingRule? in
        guard let ref = refByWindowID[windowID] else { return nil }
        return StoredPendingRule(window: ref, action: storedRuleAction(from: action))
    }.sorted { lhs, rhs in
        lhs.window.sortKey < rhs.window.sortKey
    }

    return StoredWorld(
        schemaVersion: StoredWorld.currentSchemaVersion,
        activeSpace: StoredSpace(layouts: layouts, focused: focused),
        pendingRules: pendingRules
    )
}

public func restoreWorld(
    from stored: StoredWorld,
    liveWindows: [WindowMetadata],
    displays: [DisplayID: DisplayInfo],
    activeSpace: SpaceID?,
    config: Config
) -> World {
    let windows = liveWindows.reduce(into: [:]) { result, metadata in
        result[metadata.id] = metadata
    }
    guard let activeSpace else {
        return World(
            displays: displays,
            activeSpace: nil,
            spaces: [:],
            windows: windows,
            windowDisplay: displayOwnership(for: windows.values, displays: displays),
            windowConstraints: [:],
            pendingRules: [:],
            config: config
        )
    }

    let stored = validateStoredWorld(stored).successValue ?? .empty
    var matcher = RestoreMatcher(liveWindows: Array(windows.values))
    var displayStates: [DisplayID: DisplaySpaceState] = [:]
    var restoredDisplayByWindow: [WindowID: DisplayID] = [:]

    for layout in stored.activeSpace?.layouts ?? [] {
        guard let displayID = matchDisplay(for: layout, displays: displays) else { continue }
        let tree = restoreNode(layout.tree, matcher: &matcher, displayID: displayID, restoredDisplayByWindow: &restoredDisplayByWindow)
        let floating = layout.floating.compactMap { ref -> WindowID? in
            guard let windowID = matcher.take(ref) else { return nil }
            restoredDisplayByWindow[windowID] = displayID
            return windowID
        }
        displayStates[displayID] = DisplaySpaceState(displayID: displayID, tree: tree, floating: floating)
    }

    var windowDisplay = displayOwnership(for: windows.values, displays: displays)
    for (windowID, displayID) in restoredDisplayByWindow {
        windowDisplay[windowID] = displayID
    }

    for displayID in displays.keys {
        let existing = displayStates[displayID] ?? DisplaySpaceState(displayID: displayID, tree: .void, floating: [])
        let alreadyAssigned = Set(occupiedWindows(in: existing.tree)).union(existing.floating)
        let floating = existing.floating + windowDisplay
            .filter { windowID, ownedDisplayID in
                ownedDisplayID == displayID && !alreadyAssigned.contains(windowID)
            }
            .map(\.key)
            .sorted { $0.raw < $1.raw }
        displayStates[displayID] = DisplaySpaceState(displayID: displayID, tree: existing.tree, floating: floating)
    }

    let focused = stored.activeSpace?.focused.flatMap { matcher.lookup($0) }
    return World(
        displays: displays,
        activeSpace: activeSpace,
        spaces: [
            activeSpace: SpaceState(id: activeSpace, displays: displayStates, focused: focused)
        ],
        windows: windows,
        windowDisplay: windowDisplay,
        windowConstraints: [:],
        pendingRules: restoredPendingRules(stored.pendingRules, matcher: matcher),
        config: config
    )
}

private extension StoredWorld {
    var allWindowRefs: [StoredWindowRef] {
        var refs: [StoredWindowRef] = []
        if let activeSpace {
            for layout in activeSpace.layouts {
                refs.append(contentsOf: layout.tree.windowRefs)
                refs.append(contentsOf: layout.floating)
            }
            if let focused = activeSpace.focused {
                refs.append(focused)
            }
        }
        refs.append(contentsOf: pendingRules.map(\.window))
        return refs
    }
}

private struct RestoreWindowKey: Hashable {
    let bundleID: BundleID
    let title: String
    let role: String
}

private struct RestoreMatcher {
    private let candidatesByKey: [RestoreWindowKey: [WindowMetadata]]
    private var consumed: Set<WindowID> = []

    init(liveWindows: [WindowMetadata]) {
        candidatesByKey = Dictionary(grouping: liveWindows, by: \.restoreKey).mapValues(stableWindowOrder)
    }

    mutating func take(_ ref: StoredWindowRef) -> WindowID? {
        guard let metadata = bestCandidate(
            for: ref,
            in: candidatesByKey[ref.restoreKey, default: []],
            excluding: consumed
        ) else { return nil }
        consumed.insert(metadata.id)
        return metadata.id
    }

    func lookup(_ ref: StoredWindowRef) -> WindowID? {
        bestCandidate(for: ref, in: candidatesByKey[ref.restoreKey, default: []], excluding: [])?.id
    }

    private func bestCandidate(
        for ref: StoredWindowRef,
        in candidates: [WindowMetadata],
        excluding consumed: Set<WindowID>
    ) -> WindowMetadata? {
        if candidates.indices.contains(ref.occurrence) {
            let candidate = candidates[ref.occurrence]
            return consumed.contains(candidate.id) ? nil : candidate
        }
        guard let frame = ref.lastKnownFrame else { return nil }
        let ranked = candidates.filter { !consumed.contains($0.id) }
            .map { ($0, frameDistanceSquared($0.frame, frame)) }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.id.raw < rhs.0.id.raw
                }
                return lhs.1 < rhs.1
            }
        guard let first = ranked.first else { return nil }
        if ranked.count > 1 && ranked[0].1 == ranked[1].1 {
            return nil
        }
        return first.0
    }
}

private func storedRefsByWindowID(for windows: [WindowID: WindowMetadata]) -> [WindowID: StoredWindowRef] {
    Dictionary(grouping: Array(windows.values), by: \.restoreKey).values.reduce(into: [:]) { result, group in
        for (occurrence, metadata) in stableWindowOrder(group).enumerated() {
            result[metadata.id] = StoredWindowRef(
                bundleID: metadata.bundleID,
                title: metadata.title,
                role: metadata.role,
                occurrence: occurrence,
                lastKnownFrame: metadata.frame
            )
        }
    }
}

private func storedNode(from node: Node, refs: [WindowID: StoredWindowRef]) -> StoredNode {
    switch node {
    case .void:
        return .void
    case .leaf(let windowID):
        return refs[windowID].map(StoredNode.leaf) ?? .void
    case .split(let split):
        return .split(makeStoredSplit(
            axis: split.axis,
            cells: split.cells.map { cell in
                makeStoredCell(weight: cell.weight, node: storedNode(from: cell.node, refs: refs))
            }
        ))
    }
}

private func restoreNode(
    _ node: StoredNode,
    matcher: inout RestoreMatcher,
    displayID: DisplayID,
    restoredDisplayByWindow: inout [WindowID: DisplayID]
) -> Node {
    switch node {
    case .void:
        return .void
    case .leaf(let ref):
        guard let windowID = matcher.take(ref) else { return .void }
        restoredDisplayByWindow[windowID] = displayID
        return .leaf(windowID)
    case .split(let split):
        return .split(makeSplit(
            axis: split.axis,
            cells: split.cells.map { cell in
                makeCell(
                    weight: cell.weight,
                    node: restoreNode(
                        cell.node,
                        matcher: &matcher,
                        displayID: displayID,
                        restoredDisplayByWindow: &restoredDisplayByWindow
                    )
                )
            }
        ))
    }
}

private func restoredPendingRules(_ stored: [StoredPendingRule], matcher: RestoreMatcher) -> [WindowID: RuleAction] {
    stored.reduce(into: [:]) { result, pending in
        guard let windowID = matcher.lookup(pending.window) else { return }
        result[windowID] = ruleAction(from: pending.action)
    }
}

private func storedRuleAction(from action: RuleAction) -> StoredRuleAction {
    switch action {
    case .forceFloat:
        return .forceFloat
    case .ignore:
        return .ignore
    case .pinToDisplay(let slot):
        return .pinToDisplay(displaySlot: slot)
    }
}

private func ruleAction(from action: StoredRuleAction) -> RuleAction {
    switch action {
    case .forceFloat:
        return .forceFloat
    case .ignore:
        return .ignore
    case .pinToDisplay(let displaySlot):
        return .pinToDisplay(slot: displaySlot)
    }
}

private func matchDisplay(for layout: StoredDisplayLayout, displays: [DisplayID: DisplayInfo]) -> DisplayID? {
    if let fingerprint = layout.displayFingerprint,
       let exact = displays.first(where: { $0.value.fingerprint == fingerprint }) {
        return exact.key
    }
    return displays.first(where: { $0.value.slot == layout.displaySlot })?.key
}

private func displayOwnership(
    for windows: Dictionary<WindowID, WindowMetadata>.Values,
    displays: [DisplayID: DisplayInfo]
) -> [WindowID: DisplayID] {
    windows.reduce(into: [:]) { result, metadata in
        guard let displayID = displayContaining(frame: metadata.frame, displays: displays) else { return }
        result[metadata.id] = displayID
    }
}

private func displayContaining(frame: CGRect, displays: [DisplayID: DisplayInfo]) -> DisplayID? {
    if let byIntersection = displays.max(by: { lhs, rhs in
        lhs.value.visibleFrame.intersection(frame).area < rhs.value.visibleFrame.intersection(frame).area
    }), byIntersection.value.visibleFrame.intersection(frame).area > 0 {
        return byIntersection.key
    }

    let center = CGPoint(x: frame.midX, y: frame.midY)
    return displays.min(by: { lhs, rhs in
        lhs.value.visibleFrame.center.distanceSquared(to: center) < rhs.value.visibleFrame.center.distanceSquared(to: center)
    })?.key
}

private func stableWindowOrder(_ windows: [WindowMetadata]) -> [WindowMetadata] {
    windows.sorted { lhs, rhs in
        lhs.restoreSortKey < rhs.restoreSortKey
    }
}

private func frameDistanceSquared(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let dx = lhs.midX - rhs.midX
    let dy = lhs.midY - rhs.midY
    return dx * dx + dy * dy
}

private func makeStoredCell(weight: Double, node: StoredNode) -> StoredCell {
    switch StoredCell.create(weight: weight, node: node) {
    case .success(let cell):
        return cell
    case .failure(let error):
        preconditionFailure("Invalid StoredCell in restore projection: \(error)")
    }
}

private func makeStoredSplit(axis: Axis, cells: [StoredCell]) -> StoredSplit {
    switch StoredSplit.create(axis: axis, cells: cells) {
    case .success(let split):
        return split
    case .failure(let error):
        preconditionFailure("Invalid StoredSplit in restore projection: \(error)")
    }
}

private func makeCell(weight: Double, node: Node) -> Cell {
    switch Cell.create(weight: weight, node: node) {
    case .success(let cell):
        return cell
    case .failure(let error):
        preconditionFailure("Invalid Cell in restore remap: \(error)")
    }
}

private func makeSplit(axis: Axis, cells: [Cell]) -> Split {
    switch Split.create(axis: axis, cells: cells) {
    case .success(let split):
        return split
    case .failure(let error):
        preconditionFailure("Invalid Split in restore remap: \(error)")
    }
}

private extension WindowMetadata {
    var restoreKey: RestoreWindowKey {
        RestoreWindowKey(bundleID: bundleID, title: title, role: role)
    }

    var restoreSortKey: StoredWindowSortKey {
        StoredWindowSortKey(
            minY: frame.minY,
            minX: frame.minX,
            width: frame.width,
            height: frame.height,
            pid: pid,
            windowID: id.raw
        )
    }
}

private extension StoredWindowRef {
    var restoreKey: RestoreWindowKey {
        RestoreWindowKey(bundleID: bundleID, title: title, role: role)
    }

    var sortKey: StoredWindowRefSortKey {
        StoredWindowRefSortKey(bundleID: bundleID.raw, title: title, role: role, occurrence: occurrence)
    }
}

private struct StoredWindowRefSortKey: Comparable {
    let bundleID: String
    let title: String
    let role: String
    let occurrence: Int

    static func < (lhs: StoredWindowRefSortKey, rhs: StoredWindowRefSortKey) -> Bool {
        if lhs.bundleID != rhs.bundleID { return lhs.bundleID < rhs.bundleID }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        if lhs.role != rhs.role { return lhs.role < rhs.role }
        return lhs.occurrence < rhs.occurrence
    }
}

private struct StoredWindowSortKey: Comparable {
    let minY: CGFloat
    let minX: CGFloat
    let width: CGFloat
    let height: CGFloat
    let pid: ProcessID
    let windowID: CGWindowID

    static func < (lhs: StoredWindowSortKey, rhs: StoredWindowSortKey) -> Bool {
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        if lhs.width != rhs.width { return lhs.width < rhs.width }
        if lhs.height != rhs.height { return lhs.height < rhs.height }
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        return lhs.windowID < rhs.windowID
    }
}

private extension StoredNode {
    var windowRefs: [StoredWindowRef] {
        switch self {
        case .void:
            return []
        case .leaf(let ref):
            return [ref]
        case .split(let split):
            return split.cells.flatMap { $0.node.windowRefs }
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var hasNonFiniteCoordinate: Bool {
        [origin.x, origin.y, size.width, size.height].contains { !$0.isFinite }
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}

private extension Result {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}
