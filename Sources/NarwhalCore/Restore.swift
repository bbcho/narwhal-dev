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

public struct StoredWorkspace: Equatable, Codable, Sendable {
    public let spaceID: SpaceID
    public let space: StoredSpace

    public init(spaceID: SpaceID, space: StoredSpace) {
        self.spaceID = spaceID
        self.space = space
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
    case tileToZone(ZoneID)
}

public struct StoredWorld: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 2
    public static let empty = StoredWorld(
        schemaVersion: currentSchemaVersion,
        activeSpace: nil,
        workspaces: [],
        pendingRules: []
    )

    public let schemaVersion: Int
    public let activeSpace: StoredSpace?
    public let workspaces: [StoredWorkspace]?
    public let pendingRules: [StoredPendingRule]

    public init(
        schemaVersion: Int,
        activeSpace: StoredSpace?,
        workspaces: [StoredWorkspace]? = nil,
        pendingRules: [StoredPendingRule]
    ) {
        self.schemaVersion = schemaVersion
        self.activeSpace = activeSpace
        self.workspaces = workspaces
        self.pendingRules = pendingRules
    }
}

public func validateStoredWorld(_ stored: StoredWorld) -> Result<StoredWorld, RestoreError> {
    guard (1...StoredWorld.currentSchemaVersion).contains(stored.schemaVersion) else {
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
    guard !world.spaces.isEmpty else {
        return .empty
    }

    let refByWindowID = storedRefsByWindowID(for: world.windows)
    let storedSpacesByID = world.spaces.mapValues { space in
        storedSpace(from: space, world: world, refs: refByWindowID)
    }
    let pendingRules = world.pendingRules.compactMap { windowID, action -> StoredPendingRule? in
        guard let ref = refByWindowID[windowID] else { return nil }
        return StoredPendingRule(window: ref, action: storedRuleAction(from: action))
    }.sorted { lhs, rhs in
        lhs.window.sortKey < rhs.window.sortKey
    }

    return StoredWorld(
        schemaVersion: StoredWorld.currentSchemaVersion,
        activeSpace: world.activeSpace.flatMap { storedSpacesByID[$0] },
        workspaces: storedSpacesByID
            .map { StoredWorkspace(spaceID: $0.key, space: $0.value) }
            .sorted { $0.spaceID.raw < $1.spaceID.raw },
        pendingRules: pendingRules
    )
}

private func storedSpace(
    from space: SpaceState,
    world: World,
    refs refByWindowID: [WindowID: StoredWindowRef]
) -> StoredSpace {
    let layouts = space.displays.compactMap { displayID, displayState -> StoredDisplayLayout? in
        guard let display = world.displays[displayID] else { return nil }
        return StoredDisplayLayout(
            displaySlot: display.slot,
            displayFingerprint: display.fingerprint,
            tree: storedNode(from: displayState.tree, refs: refByWindowID),
            floating: sanitizedFloatingIDs(in: displayState).compactMap { refByWindowID[$0] }
        )
    }.sorted { lhs, rhs in
        if lhs.displaySlot == rhs.displaySlot {
            return (lhs.displayFingerprint ?? "") < (rhs.displayFingerprint ?? "")
        }
        return lhs.displaySlot < rhs.displaySlot
    }
    return StoredSpace(layouts: layouts, focused: space.focused.flatMap { refByWindowID[$0] })
}

public func restoreWorld(
    from stored: StoredWorld,
    liveWindows: [WindowMetadata],
    displays: [DisplayID: DisplayInfo],
    activeSpace: SpaceID?,
    spaceTopology: SpaceTopology? = nil,
    config: Config
) -> World {
    let windows = Dictionary(liveWindows.map { ($0.id, $0) }, uniquingKeysWith: { _, replacement in replacement })
    let activeSpaceByDisplay: [DisplayID: SpaceID]
    if let topologyActiveSpaces = spaceTopology?.activeSpaceByDisplay, !topologyActiveSpaces.isEmpty {
        activeSpaceByDisplay = topologyActiveSpaces
    } else if let activeSpace {
        activeSpaceByDisplay = Dictionary(uniqueKeysWithValues: displays.keys.map { ($0, activeSpace) })
    } else {
        activeSpaceByDisplay = [:]
    }
    let liveWindowSpace = spaceTopology?.windowSpace ?? [:]
    guard let activeSpace else {
        return World(
            displays: displays,
            activeSpace: nil,
            activeSpaceByDisplay: activeSpaceByDisplay,
            spaces: [:],
            windows: windows,
            windowDisplay: displayOwnership(for: windows.values, displays: displays),
            windowSpace: liveWindowSpace,
            observedVisibleWindows: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: config
        )
    }

    let stored = validateStoredWorld(stored).successValue ?? .empty
    let matcher = RestoreMatcher(liveWindows: Array(windows.values))
    let storedSpaces: [(SpaceID, StoredSpace)]
    if let workspaces = stored.workspaces, !workspaces.isEmpty {
        storedSpaces = workspaces.map { ($0.spaceID, $0.space) }
    } else {
        storedSpaces = stored.activeSpace.map { [(activeSpace, $0)] } ?? []
    }
    let projection = restoreSpaces(storedSpaces, matcher: matcher, displays: displays)
    let windowDisplay = displayOwnership(for: windows.values, displays: displays)
        .merging(projection.displayByWindow) { _, restored in restored }
    let windowSpace = restoredWindowSpace(
        liveWindowSpace: liveWindowSpace,
        restoredSpaceByWindow: projection.spaceByWindow,
        windowDisplay: windowDisplay,
        activeSpaceByDisplay: activeSpaceByDisplay,
        fallbackSpace: activeSpace
    )
    let spaces = spacesByAddingDisplayFloatingWindows(
        spaces: spacesWithActiveFallbacks(
            projection.spaces,
            activeSpaceByDisplay: activeSpaceByDisplay,
            activeSpace: activeSpace
        ),
        displays: displays,
        windowDisplay: windowDisplay,
        windowSpace: windowSpace
    )

    return World(
        displays: displays,
        activeSpace: activeSpace,
        activeSpaceByDisplay: activeSpaceByDisplay,
        spaces: sanitizedSpaces(spaces),
        windows: windows,
        windowDisplay: windowDisplay,
        windowSpace: windowSpace,
        observedVisibleWindows: [:],
        windowConstraints: [:],
        pendingRules: restoredPendingRules(stored.pendingRules, matcher: projection.matcher),
        config: config
    )
}

private extension StoredWorld {
    var allWindowRefs: [StoredWindowRef] {
        (activeSpace.map(storedWindowRefs(in:)) ?? [])
            + (workspaces ?? []).flatMap { storedWindowRefs(in: $0.space) }
            + pendingRules.map(\.window)
    }
}

private func storedWindowRefs(in space: StoredSpace) -> [StoredWindowRef] {
    space.layouts.flatMap { $0.tree.windowRefs + $0.floating }
        + (space.focused.map { [$0] } ?? [])
}

private struct RestoreWindowKey: Hashable {
    let bundleID: BundleID
    let title: String
    let role: String
}

private struct RestoreMatcher {
    private let candidatesByKey: [RestoreWindowKey: [WindowMetadata]]
    private let consumed: Set<WindowID>

    init(liveWindows: [WindowMetadata]) {
        self.init(
            candidatesByKey: Dictionary(grouping: liveWindows, by: \.restoreKey).mapValues(stableWindowOrder),
            consumed: []
        )
    }

    private init(candidatesByKey: [RestoreWindowKey: [WindowMetadata]], consumed: Set<WindowID>) {
        self.candidatesByKey = candidatesByKey
        self.consumed = consumed
    }

    func taking(_ ref: StoredWindowRef) -> RestoreMatch {
        guard let metadata = bestCandidate(
            for: ref,
            in: candidatesByKey[ref.restoreKey, default: []],
            excluding: consumed
        ) else { return RestoreMatch(matcher: self, windowID: nil) }
        return RestoreMatch(
            matcher: RestoreMatcher(candidatesByKey: candidatesByKey, consumed: consumed.union([metadata.id])),
            windowID: metadata.id
        )
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

private struct RestoreMatch {
    let matcher: RestoreMatcher
    let windowID: WindowID?
}

private func storedRefsByWindowID(for windows: [WindowID: WindowMetadata]) -> [WindowID: StoredWindowRef] {
    Dictionary(
        Dictionary(grouping: Array(windows.values), by: \.restoreKey).values.flatMap { group in
            stableWindowOrder(group).enumerated().map { occurrence, metadata in
                (
                    metadata.id,
                    StoredWindowRef(
                        bundleID: metadata.bundleID,
                        title: metadata.title,
                        role: metadata.role,
                        occurrence: occurrence,
                        lastKnownFrame: metadata.frame
                    )
                )
            }
        },
        uniquingKeysWith: { _, replacement in replacement }
    )
}

private struct RestoredSpacesProjection {
    let matcher: RestoreMatcher
    let spaces: [SpaceID: SpaceState]
    let displayByWindow: [WindowID: DisplayID]
    let spaceByWindow: [WindowID: SpaceID]

    static func empty(matcher: RestoreMatcher) -> RestoredSpacesProjection {
        RestoredSpacesProjection(matcher: matcher, spaces: [:], displayByWindow: [:], spaceByWindow: [:])
    }
}

private func restoreSpaces(
    _ storedSpaces: [(SpaceID, StoredSpace)],
    matcher: RestoreMatcher,
    displays: [DisplayID: DisplayInfo]
) -> RestoredSpacesProjection {
    storedSpaces.reduce(.empty(matcher: matcher)) { state, storedSpace in
        let restoredSpace = restoreSpace(
            storedSpace.1,
            spaceID: storedSpace.0,
            matcher: state.matcher,
            displays: displays
        )
        return RestoredSpacesProjection(
            matcher: restoredSpace.matcher,
            spaces: state.spaces.setting(storedSpace.0, to: restoredSpace.space),
            displayByWindow: state.displayByWindow.merging(restoredSpace.displayByWindow) { _, restored in restored },
            spaceByWindow: state.spaceByWindow.merging(restoredSpace.spaceByWindow) { _, restored in restored }
        )
    }
}

private struct RestoredSpaceProjection {
    let matcher: RestoreMatcher
    let space: SpaceState
    let displayByWindow: [WindowID: DisplayID]
    let spaceByWindow: [WindowID: SpaceID]
}

private struct RestoredDisplayAccumulator {
    let matcher: RestoreMatcher
    let displayStates: [DisplayID: DisplaySpaceState]
    let displayByWindow: [WindowID: DisplayID]
    let spaceByWindow: [WindowID: SpaceID]
}

private func restoreSpace(
    _ storedSpace: StoredSpace,
    spaceID: SpaceID,
    matcher: RestoreMatcher,
    displays: [DisplayID: DisplayInfo]
) -> RestoredSpaceProjection {
    let restoredDisplays = storedSpace.layouts.reduce(
        RestoredDisplayAccumulator(matcher: matcher, displayStates: [:], displayByWindow: [:], spaceByWindow: [:])
    ) { state, layout in
        guard let displayID = matchDisplay(for: layout, displays: displays) else { return state }
        let restoredLayout = restoreLayout(
            layout,
            displayID: displayID,
            spaceID: spaceID,
            matcher: state.matcher
        )
        return RestoredDisplayAccumulator(
            matcher: restoredLayout.matcher,
            displayStates: state.displayStates.setting(displayID, to: restoredLayout.displayState),
            displayByWindow: state.displayByWindow.merging(restoredLayout.displayByWindow) { _, restored in restored },
            spaceByWindow: state.spaceByWindow.merging(restoredLayout.spaceByWindow) { _, restored in restored }
        )
    }
    let focused = storedSpace.focused.flatMap { restoredDisplays.matcher.lookup($0) }
    return RestoredSpaceProjection(
        matcher: restoredDisplays.matcher,
        space: SpaceState(id: spaceID, displays: restoredDisplays.displayStates, focused: focused),
        displayByWindow: restoredDisplays.displayByWindow,
        spaceByWindow: restoredDisplays.spaceByWindow
    )
}

private struct RestoredLayoutProjection {
    let matcher: RestoreMatcher
    let displayState: DisplaySpaceState
    let displayByWindow: [WindowID: DisplayID]
    let spaceByWindow: [WindowID: SpaceID]
}

private struct RestoredFloatingAccumulator {
    let matcher: RestoreMatcher
    let floating: [WindowID]
    let displayByWindow: [WindowID: DisplayID]
    let spaceByWindow: [WindowID: SpaceID]
}

private func restoreLayout(
    _ layout: StoredDisplayLayout,
    displayID: DisplayID,
    spaceID: SpaceID,
    matcher: RestoreMatcher
) -> RestoredLayoutProjection {
    let restoredTree = restoreNode(layout.tree, matcher: matcher, displayID: displayID, spaceID: spaceID)
    let restoredFloating = layout.floating.reduce(
        RestoredFloatingAccumulator(
            matcher: restoredTree.matcher,
            floating: [],
            displayByWindow: restoredTree.displayByWindow,
            spaceByWindow: restoredTree.spaceByWindow
        )
    ) { state, ref in
        let match = state.matcher.taking(ref)
        guard let windowID = match.windowID else {
            return RestoredFloatingAccumulator(
                matcher: match.matcher,
                floating: state.floating,
                displayByWindow: state.displayByWindow,
                spaceByWindow: state.spaceByWindow
            )
        }
        return RestoredFloatingAccumulator(
            matcher: match.matcher,
            floating: state.floating + [windowID],
            displayByWindow: state.displayByWindow.setting(windowID, to: displayID),
            spaceByWindow: state.spaceByWindow.setting(windowID, to: spaceID)
        )
    }
    return RestoredLayoutProjection(
        matcher: restoredFloating.matcher,
        displayState: DisplaySpaceState(displayID: displayID, tree: restoredTree.node, floating: restoredFloating.floating),
        displayByWindow: restoredFloating.displayByWindow,
        spaceByWindow: restoredFloating.spaceByWindow
    )
}

private struct RestoredNodeProjection {
    let matcher: RestoreMatcher
    let node: Node
    let displayByWindow: [WindowID: DisplayID]
    let spaceByWindow: [WindowID: SpaceID]
}

private struct RestoredCellAccumulator {
    let matcher: RestoreMatcher
    let cells: [Cell]
    let displayByWindow: [WindowID: DisplayID]
    let spaceByWindow: [WindowID: SpaceID]
}

private func restoreNode(
    _ node: StoredNode,
    matcher: RestoreMatcher,
    displayID: DisplayID,
    spaceID: SpaceID
) -> RestoredNodeProjection {
    switch node {
    case .void:
        return RestoredNodeProjection(matcher: matcher, node: .void, displayByWindow: [:], spaceByWindow: [:])
    case .leaf(let ref):
        let match = matcher.taking(ref)
        guard let windowID = match.windowID else {
            return RestoredNodeProjection(matcher: match.matcher, node: .void, displayByWindow: [:], spaceByWindow: [:])
        }
        return RestoredNodeProjection(
            matcher: match.matcher,
            node: .leaf(windowID),
            displayByWindow: [windowID: displayID],
            spaceByWindow: [windowID: spaceID]
        )
    case .split(let split):
        let restoredCells = split.cells.reduce(
            RestoredCellAccumulator(matcher: matcher, cells: [], displayByWindow: [:], spaceByWindow: [:])
        ) { state, cell in
            let restoredNode = restoreNode(
                cell.node,
                matcher: state.matcher,
                displayID: displayID,
                spaceID: spaceID
            )
            return RestoredCellAccumulator(
                matcher: restoredNode.matcher,
                cells: state.cells + [makeCell(weight: cell.weight, node: restoredNode.node)],
                displayByWindow: state.displayByWindow.merging(restoredNode.displayByWindow) { _, restored in restored },
                spaceByWindow: state.spaceByWindow.merging(restoredNode.spaceByWindow) { _, restored in restored }
            )
        }
        return RestoredNodeProjection(
            matcher: restoredCells.matcher,
            node: .split(makeSplit(axis: split.axis, cells: restoredCells.cells)),
            displayByWindow: restoredCells.displayByWindow,
            spaceByWindow: restoredCells.spaceByWindow
        )
    }
}

private func restoredWindowSpace(
    liveWindowSpace: [WindowID: SpaceID],
    restoredSpaceByWindow: [WindowID: SpaceID],
    windowDisplay: [WindowID: DisplayID],
    activeSpaceByDisplay: [DisplayID: SpaceID],
    fallbackSpace: SpaceID
) -> [WindowID: SpaceID] {
    let restored = liveWindowSpace.merging(restoredSpaceByWindow) { _, restored in restored }
    return windowDisplay.reduce(restored) { state, ownership in
        let (windowID, displayID) = ownership
        guard state[windowID] == nil else { return state }
        return state.setting(windowID, to: activeSpaceByDisplay[displayID] ?? fallbackSpace)
    }
}

private func spacesWithActiveFallbacks(
    _ spaces: [SpaceID: SpaceState],
    activeSpaceByDisplay: [DisplayID: SpaceID],
    activeSpace: SpaceID
) -> [SpaceID: SpaceState] {
    Set(activeSpaceByDisplay.values).union([activeSpace]).reduce(spaces) { state, spaceID in
        guard state[spaceID] == nil else { return state }
        return state.setting(spaceID, to: SpaceState(id: spaceID, displays: [:], focused: nil))
    }
}

private func spacesByAddingDisplayFloatingWindows(
    spaces: [SpaceID: SpaceState],
    displays: [DisplayID: DisplayInfo],
    windowDisplay: [WindowID: DisplayID],
    windowSpace: [WindowID: SpaceID]
) -> [SpaceID: SpaceState] {
    spaces.reduce([:]) { state, entry in
        let (spaceID, space) = entry
        return state.setting(
            spaceID,
            to: spaceByAddingDisplayFloatingWindows(
                space,
                displays: displays,
                windowDisplay: windowDisplay,
                windowSpace: windowSpace
            )
        )
    }
}

private func spaceByAddingDisplayFloatingWindows(
    _ space: SpaceState,
    displays: [DisplayID: DisplayInfo],
    windowDisplay: [WindowID: DisplayID],
    windowSpace: [WindowID: SpaceID]
) -> SpaceState {
    let displayStates = displays.keys.reduce(space.displays) { state, displayID in
        let existing = state[displayID] ?? DisplaySpaceState(displayID: displayID, tree: .void, floating: [])
        let alreadyAssigned = Set(occupiedWindows(in: existing.tree)).union(existing.floating)
        let floating = existing.floating + windowDisplay
            .filter { windowID, ownedDisplayID in
                ownedDisplayID == displayID
                    && windowSpace[windowID] == space.id
                    && !alreadyAssigned.contains(windowID)
            }
            .map(\.key)
            .sorted { $0.raw < $1.raw }
        return state.setting(displayID, to: DisplaySpaceState(displayID: displayID, tree: existing.tree, floating: floating))
    }
    return SpaceState(id: space.id, displays: displayStates, focused: space.focused)
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

private func restoredPendingRules(_ stored: [StoredPendingRule], matcher: RestoreMatcher) -> [WindowID: RuleAction] {
    Dictionary(
        stored.compactMap { pending -> (WindowID, RuleAction)? in
            guard let windowID = matcher.lookup(pending.window) else { return nil }
            return (windowID, ruleAction(from: pending.action))
        },
        uniquingKeysWith: { _, replacement in replacement }
    )
}

private func storedRuleAction(from action: RuleAction) -> StoredRuleAction {
    switch action {
    case .forceFloat:
        return .forceFloat
    case .ignore:
        return .ignore
    case .pinToDisplay(let slot):
        return .pinToDisplay(displaySlot: slot)
    case .tileToZone(let zoneID):
        return .tileToZone(zoneID)
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
    case .tileToZone(let zoneID):
        return .tileToZone(zoneID)
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
    Dictionary(
        windows.compactMap { metadata -> (WindowID, DisplayID)? in
            guard let displayID = displayContaining(frame: metadata.frame, displays: displays) else { return nil }
            return (metadata.id, displayID)
        },
        uniquingKeysWith: { _, replacement in replacement }
    )
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
