import CoreGraphics
import NarwhalCore

public enum WindowManagementState: Equatable, Sendable {
    case tiled
    case floating
    case manualAdjustment
    case temporarilyDetached(TemporaryDetachmentReason)

    public var label: String {
        switch self {
        case .tiled: return "Tiled"
        case .floating: return "Floating"
        case .manualAdjustment: return "Adjusting"
        case .temporarilyDetached: return "Detached"
        }
    }
}

public enum WorkspaceHealth: Equatable, Sendable {
    case ready
    case partialInventory(errorCount: Int)
    case permissionRequired
    case unavailable(String)
    case constraintConflict(UnsatisfiableLayout)

    public var label: String {
        switch self {
        case .ready: return "Ready"
        case .partialInventory: return "Partial inventory"
        case .permissionRequired: return "Permission required"
        case .unavailable: return "Unavailable"
        case .constraintConflict: return "Constraint conflict"
        }
    }
}

public struct WindowPresentation: Equatable, Sendable {
    public let id: WindowID
    public let title: String
    public let bundleID: BundleID
    public let role: String
    public let frame: CGRect
    public let workspaceKey: WorkspaceKey
    public let state: WindowManagementState
    public let isFocused: Bool
    public let constraints: WindowConstraints
    public let ruleSource: WindowRuleSource

    public init(
        id: WindowID,
        title: String,
        bundleID: BundleID,
        role: String,
        frame: CGRect,
        workspaceKey: WorkspaceKey,
        state: WindowManagementState,
        isFocused: Bool,
        constraints: WindowConstraints,
        ruleSource: WindowRuleSource
    ) {
        self.id = id
        self.title = title
        self.bundleID = bundleID
        self.role = role
        self.frame = frame
        self.workspaceKey = workspaceKey
        self.state = state
        self.isFocused = isFocused
        self.constraints = constraints
        self.ruleSource = ruleSource
    }
}

public struct WorkspacePresentation: Equatable, Sendable {
    public let key: WorkspaceKey
    public let displaySlot: Int
    public let displayFrame: CGRect
    public let visibleFrame: CGRect
    public let tree: Node
    public let windows: [WindowPresentation]
    public let health: WorkspaceHealth
    public let isActive: Bool

    public init(
        key: WorkspaceKey,
        displaySlot: Int,
        displayFrame: CGRect,
        visibleFrame: CGRect,
        tree: Node,
        windows: [WindowPresentation],
        health: WorkspaceHealth,
        isActive: Bool
    ) {
        self.key = key
        self.displaySlot = displaySlot
        self.displayFrame = displayFrame
        self.visibleFrame = visibleFrame
        self.tree = tree
        self.windows = windows
        self.health = health
        self.isActive = isActive
    }

    public var tiledCount: Int {
        windows.count { $0.state == .tiled || $0.state == .manualAdjustment }
    }

    public var floatingCount: Int {
        windows.count { $0.state == .floating }
    }
}

public struct WorkbenchPresentation: Equatable, Sendable {
    public let activeSpaceID: SpaceID?
    public let workspaces: [WorkspacePresentation]

    public init(activeSpaceID: SpaceID?, workspaces: [WorkspacePresentation]) {
        self.activeSpaceID = activeSpaceID
        self.workspaces = workspaces
    }
}

public func workbenchPresentation(
    in world: World,
    runtime: WorldRuntimeState,
    snapshotQuality: AXSnapshotQuality?
) -> WorkbenchPresentation {
    let presentations = world.spaces.keys.sorted { $0.raw < $1.raw }.flatMap { spaceID in
        guard let space = world.spaces[spaceID] else { return [WorkspacePresentation]() }
        return space.displays.keys.sorted { displaySort($0, $1, in: world) }.compactMap { displayID in
            guard let display = world.displays[displayID],
                  let displayState = space.displays[displayID]
            else { return nil }
            let key = WorkspaceKey(displayID: displayID, spaceID: spaceID)
            let focused = space.focused
            let windows = windowIDs(in: displayState).compactMap { id -> WindowPresentation? in
                guard let metadata = world.windows[id] else { return nil }
                return WindowPresentation(
                    id: id,
                    title: displayTitle(for: metadata),
                    bundleID: metadata.bundleID,
                    role: metadata.role,
                    frame: metadata.frame,
                    workspaceKey: key,
                    state: windowManagementState(
                        for: id,
                        displayState: displayState,
                        interaction: runtime.windowInteractions[id]
                    ),
                    isFocused: focused == id,
                    constraints: world.windowConstraints[id] ?? WindowConstraints(),
                    ruleSource: resolveWindowOpen(
                        metadata,
                        managedRules: world.config.managedRules,
                        luaRules: world.config.rules
                    ).source
                )
            }.sorted(by: windowPresentationSort)
            return WorkspacePresentation(
                key: key,
                displaySlot: display.slot,
                displayFrame: display.frame,
                visibleFrame: display.visibleFrame,
                tree: displayState.tree,
                windows: windows,
                health: workspaceHealth(key, in: world, snapshotQuality: snapshotQuality),
                isActive: activeSpaceID(for: displayID, in: world) == spaceID
            )
        }
    }
    return WorkbenchPresentation(activeSpaceID: world.activeSpace, workspaces: presentations)
}

public struct LayoutHistoryAvailability: Equatable, Sendable {
    public let canUndo: Bool
    public let canRedo: Bool
    public let undoLabel: String?
    public let redoLabel: String?

    public init(canUndo: Bool, canRedo: Bool, undoLabel: String?, redoLabel: String?) {
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.undoLabel = undoLabel
        self.redoLabel = redoLabel
    }
}

public func windowManagementState(
    for windowID: WindowID,
    displayState: DisplaySpaceState,
    interaction: WindowInteractionState?
) -> WindowManagementState {
    switch interaction {
    case .manualAdjustment:
        return .manualAdjustment
    case .temporarilyDetached(let reason):
        return .temporarilyDetached(reason)
    case nil:
        if occupiedWindows(in: displayState.tree).contains(windowID) {
            return .tiled
        }
        if displayState.floating.contains(windowID) {
            return .floating
        }
        return .temporarilyDetached(.reconciliationPending)
    }
}

public enum LayoutOperation: Equatable, Sendable {
    case push(Direction)
    case resize(Direction)
    case eject
    case balance
    case shuffle
    case cascade
    case reset
    case applyTemplate(String)
    case directManipulation

    public var label: String {
        switch self {
        case .push(let direction): return "Push " + direction.rawValue.capitalized
        case .resize(let direction): return "Resize " + direction.rawValue.capitalized
        case .eject: return "Eject Window"
        case .balance: return "Balance Space"
        case .shuffle: return "Shuffle Space"
        case .cascade: return "Cascade Space"
        case .reset: return "Reset Space"
        case .applyTemplate(let name): return "Apply \(name)"
        case .directManipulation: return "Edit Layout"
        }
    }
}

public enum WindowChangeKind: String, Equatable, Sendable {
    case moved
    case resized
    case shown
    case hidden
    case managementState
}

public struct PlannedWindowChange: Equatable, Sendable {
    public let windowID: WindowID
    public let title: String
    public let before: CGRect?
    public let after: CGRect?
    public let kinds: [WindowChangeKind]

    public init(windowID: WindowID, title: String, before: CGRect?, after: CGRect?, kinds: [WindowChangeKind]) {
        self.windowID = windowID
        self.title = title
        self.before = before
        self.after = after
        self.kinds = kinds
    }
}

public struct CommandPreview: Equatable, Sendable {
    public let operation: LayoutOperation
    public let spaceID: SpaceID?
    public let changes: [PlannedWindowChange]
    public let proposedLayout: Layout

    public init(
        operation: LayoutOperation,
        spaceID: SpaceID?,
        changes: [PlannedWindowChange],
        proposedLayout: Layout
    ) {
        self.operation = operation
        self.spaceID = spaceID
        self.changes = changes
        self.proposedLayout = proposedLayout
    }
}

public func commandPreview(
    operation: LayoutOperation,
    result: CommandPlanResult
) -> CommandPreview {
    let beforeWorld = result.undoWorld
    let afterWorld = result.plannedWorld
    let beforeLayout = beforeWorld.flatMap { try? flattenedLayout(of: $0).get() }
    let afterLayout = result.desiredLayout.layout
    let managementChanges = Set((beforeWorld?.windows.keys ?? afterWorld.windows.keys).filter { id in
        guard let beforeWorld else { return false }
        return basicManagementState(id, in: beforeWorld) != basicManagementState(id, in: afterWorld)
    })
    let ids = Set(result.desiredLayout.delta.moves.keys)
        .union(result.desiredLayout.delta.raises)
        .union(result.desiredLayout.delta.hides)
        .union(result.desiredLayout.delta.shows)
        .union(managementChanges)
    let changes = ids.compactMap { id -> PlannedWindowChange? in
        guard let metadata = afterWorld.windows[id] ?? beforeWorld?.windows[id] else { return nil }
        let before = beforeLayout?.tiled[id] ?? beforeWorld?.windows[id]?.frame
        let after = afterLayout.tiled[id] ?? afterWorld.windows[id]?.frame
        var kinds = [WindowChangeKind]()
        if result.desiredLayout.delta.shows.contains(id) { kinds.append(.shown) }
        if result.desiredLayout.delta.hides.contains(id) { kinds.append(.hidden) }
        if let before, let after {
            if before.origin != after.origin { kinds.append(.moved) }
            if before.size != after.size { kinds.append(.resized) }
        }
        if managementChanges.contains(id) { kinds.append(.managementState) }
        return PlannedWindowChange(
            windowID: id,
            title: displayTitle(for: metadata),
            before: before,
            after: after,
            kinds: Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue }
        )
    }.sorted { lhs, rhs in
        if lhs.title != rhs.title { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
        return lhs.windowID.raw < rhs.windowID.raw
    }
    let scopeWindow = result.focusedWindowID.flatMap { afterWorld.windows[$0] == nil ? nil : $0 }
    return CommandPreview(
        operation: operation,
        spaceID: scopeWindow.flatMap { workspaceKey(forWindow: $0, in: afterWorld)?.spaceID }
            ?? afterWorld.activeSpace,
        changes: changes,
        proposedLayout: afterLayout
    )
}

public enum CommandRecovery: Equatable, Sendable {
    case grantAccessibility
    case refreshWorkspace
    case chooseAnotherWindow
    case tileWindow
    case floatWindow
    case chooseAnotherDirection
    case reduceResize
    case relaxConstraints
    case chooseExistingZone
    case fixRule
    case fixConfiguration
}

public struct CommandExplanation: Equatable, Sendable {
    public let code: String
    public let title: String
    public let reason: String
    public let recovery: CommandRecovery

    public init(code: String, title: String, reason: String, recovery: CommandRecovery) {
        self.code = code
        self.title = title
        self.reason = reason
        self.recovery = recovery
    }
}

public func commandExplanation(for error: CommandError) -> CommandExplanation {
    switch error {
    case .windowNotFound:
        return explanation(error, "Window is no longer available", "The selected window closed or moved to another Space.", .chooseAnotherWindow)
    case .windowIsFloating:
        return explanation(error, "Window is floating", "This operation needs a tiled window with a split in the layout tree.", .tileWindow)
    case .windowIsTiled:
        return explanation(error, "Window is already tiled", "The selected window is already managed by the layout tree.", .floatWindow)
    case .windowNotResizable:
        return explanation(error, "Application prevents resizing", "The application reports that this window cannot be resized.", .chooseAnotherWindow)
    case .activeSpaceUnavailable, .spaceNotFound, .displayNotFound, .displayUnknownForWindow:
        return explanation(error, "Workspace is unavailable", "Narwhal cannot resolve the selected window to a current display and Space.", .refreshWorkspace)
    case .noFocusedWindow:
        return explanation(error, "No focused window", "Focus a visible application window before running this command.", .chooseAnotherWindow)
    case .noNeighbor:
        return explanation(error, "No window in that direction", "The selected window has no eligible neighbor in the requested direction.", .chooseAnotherDirection)
    case .invalidResizeDelta:
        return explanation(error, "Invalid resize amount", "The resize amount must be a finite, non-zero step.", .reduceResize)
    case .resizeWouldCollapseSplit:
        return explanation(error, "Split would collapse", "That resize would reduce one side of the split to zero.", .reduceResize)
    case .layoutUnsatisfiable(let conflict):
        let dimension = conflict.axis == .horizontal ? "width" : "height"
        let reason = "The windows require \(format(conflict.required)) pt of \(dimension), but the display has \(format(conflict.available)) pt available."
        return explanation(error, "Window constraints do not fit", reason, .relaxConstraints)
    case .zoneNotFound:
        return explanation(error, "Layout zone no longer exists", "The selected zone is not present in the active configuration.", .chooseExistingZone)
    case .ruleInvalid(let message):
        return explanation(error, "Rule is invalid", message, .fixRule)
    case .configInvalid(let message):
        return explanation(error, "Configuration is invalid", message, .fixConfiguration)
    }
}

private func workspaceHealth(
    _ key: WorkspaceKey,
    in world: World,
    snapshotQuality: AXSnapshotQuality?
) -> WorkspaceHealth {
    switch snapshotQuality {
    case .permissionDenied:
        return .permissionRequired
    case .partial(let errors):
        return .partialInventory(errorCount: errors.count)
    case .unavailable(let reason):
        return .unavailable(reason)
    case .complete, nil:
        switch workspaceLayout(for: key, in: world) {
        case .success: return .ready
        case .failure(let conflict): return .constraintConflict(conflict)
        }
    }
}

private func basicManagementState(_ windowID: WindowID, in world: World) -> WindowManagementState? {
    guard let key = workspaceKey(forWindow: windowID, in: world),
          let state = world.spaces[key.spaceID]?.displays[key.displayID]
    else { return nil }
    return windowManagementState(for: windowID, displayState: state, interaction: nil)
}

private func displaySort(_ lhs: DisplayID, _ rhs: DisplayID, in world: World) -> Bool {
    let left = world.displays[lhs]?.slot ?? .max
    let right = world.displays[rhs]?.slot ?? .max
    return left == right ? lhs.raw < rhs.raw : left < right
}

private func displayTitle(for metadata: WindowMetadata) -> String {
    if !metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return metadata.title
    }
    if !metadata.bundleID.raw.isEmpty {
        return metadata.bundleID.raw
    }
    return metadata.id.description
}

private func windowPresentationSort(_ lhs: WindowPresentation, _ rhs: WindowPresentation) -> Bool {
    if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
    if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
    return lhs.id.raw < rhs.id.raw
}

private func explanation(
    _ error: CommandError,
    _ title: String,
    _ reason: String,
    _ recovery: CommandRecovery
) -> CommandExplanation {
    CommandExplanation(code: error.code, title: title, reason: reason, recovery: recovery)
}

private func format(_ value: Double) -> String {
    String(format: "%.0f", value)
}
