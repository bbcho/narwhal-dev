import CoreGraphics
import WinMgrCore

struct MVPCommandResult: Sendable {
    let focusedWindowID: WindowID?
    let desiredLayout: DesiredLayout
    let windows: [WindowID: WindowMetadata]
    let plannedWorld: World
}

struct MVPFocusResult: Sendable {
    let window: WindowMetadata
    let frame: CGRect
}

struct EnvironmentRefreshResult: Sendable {
    let snapshot: EnvironmentSnapshot
    let activeSpace: SpaceID?
    let displayCount: Int
    let windowCount: Int
    let quality: AXSnapshotQuality
}

actor MVPWorldActor {
    private var world: World
    private var nextGeneration: UInt64 = 1

    init(config: Config = .default) {
        self.world = World(
            displays: [:],
            activeSpace: nil,
            spaces: [:],
            windows: [:],
            windowDisplay: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: config
        )
    }

    func refreshEnvironment(_ snapshot: EnvironmentSnapshot) -> EnvironmentRefreshResult {
        switch apply(.environmentChanged(snapshot), to: world) {
        case .success(let next):
            world = next
        case .failure:
            break
        }
        return EnvironmentRefreshResult(
            snapshot: snapshot,
            activeSpace: world.activeSpace,
            displayCount: world.displays.count,
            windowCount: world.windows.count,
            quality: snapshot.axSnapshot.quality
        )
    }

    func restore(_ stored: StoredWorld, from snapshot: EnvironmentSnapshot) -> Int {
        world = restoreWorld(
            from: stored,
            liveWindows: snapshot.axSnapshot.windows,
            displays: snapshot.displays,
            activeSpace: snapshot.activeSpace,
            config: world.config
        )
        guard let activeSpace = world.activeSpace, let space = world.spaces[activeSpace] else { return 0 }
        return space.displays.values.reduce(0) { total, state in
            total + occupiedWindows(in: state.tree).count
        }
    }

    func recordExternalFocus(_ windowID: WindowID) {
        guard case .success(let next) = apply(.windowFocusedExternally(windowID), to: world) else { return }
        world = next
    }

    func reloadConfig(_ config: Config) {
        guard case .success(let next) = apply(.reloadConfig(config), to: world) else { return }
        world = next
    }

    func reconcileLiveWindows(_ liveWindowIDs: Set<WindowID>) {
        world = pruneWorld(world, keepingLiveWindows: liveWindowIDs)
    }

    func upsertWindow(
        _ metadata: WindowMetadata,
        displayID: DisplayID,
        displays: [DisplayID: DisplayInfo]
    ) -> Result<Void, CommandError> {
        guard let activeSpace = world.activeSpace else {
            return .failure(.activeSpaceUnavailable)
        }

        var windows = world.windows
        windows[metadata.id] = metadata

        var windowDisplay = world.windowDisplay
        windowDisplay[metadata.id] = displayID

        var spaces = world.spaces
        if spaces[activeSpace] == nil {
            spaces[activeSpace] = SpaceState(id: activeSpace, displays: [:], focused: nil)
        }

        world = World(
            displays: displays,
            activeSpace: activeSpace,
            spaces: spaces,
            windows: windows,
            windowDisplay: windowDisplay,
            windowConstraints: world.windowConstraints,
            pendingRules: world.pendingRules,
            config: world.config
        )
        return .success(())
    }

    func planPush(_ windowID: WindowID, direction: Direction) -> Result<MVPCommandResult, CommandError> {
        planLayoutCommand(.push(windowID, direction), focusedWindowID: windowID)
    }

    func planDrop(windowID: WindowID, displayID: DisplayID, zoneID: ZoneID) -> Result<MVPCommandResult, CommandError> {
        planLayoutCommand(.dropAtZone(windowID, displayID, zoneID), focusedWindowID: windowID)
    }

    private func planLayoutCommand(
        _ command: Command,
        focusedWindowID: WindowID?
    ) -> Result<MVPCommandResult, CommandError> {
        let oldLayout: Layout
        switch flattenedLayout(of: world) {
        case .success(let layout):
            oldLayout = layout
        case .failure(let unsatisfiable):
            return .failure(.layoutUnsatisfiable(unsatisfiable))
        }

        switch apply(command, to: world) {
        case .success(let newWorld):
            let newLayout: Layout
            switch flattenedLayout(of: newWorld) {
            case .success(let layout):
                newLayout = layout
            case .failure(let unsatisfiable):
                return .failure(.layoutUnsatisfiable(unsatisfiable))
            }
            let desired = DesiredLayout(
                generation: LayoutGeneration(raw: nextGeneration),
                layout: newLayout,
                delta: diff(old: oldLayout, new: newLayout)
            )
            nextGeneration += 1
            return .success(MVPCommandResult(
                focusedWindowID: focusedWindowID,
                desiredLayout: desired,
                windows: newWorld.windows,
                plannedWorld: newWorld
            ))
        case .failure(let error):
            return .failure(error)
        }
    }

    func planCurrentLayout() -> Result<MVPCommandResult?, CommandError> {
        let newLayout: Layout
        switch flattenedLayout(of: world) {
        case .success(let layout):
            newLayout = layout
        case .failure(let unsatisfiable):
            return .failure(.layoutUnsatisfiable(unsatisfiable))
        }
        guard !newLayout.tiled.isEmpty else {
            return .success(nil)
        }

        let desired = DesiredLayout(
            generation: LayoutGeneration(raw: nextGeneration),
            layout: newLayout,
            delta: LayoutDelta(
                moves: newLayout.tiled,
                raises: [],
                hides: [],
                shows: Set(newLayout.tiled.keys)
            )
        )
        nextGeneration += 1
        return .success(MVPCommandResult(
            focusedWindowID: nil,
            desiredLayout: desired,
            windows: world.windows,
            plannedWorld: world
        ))
    }

    func planFocusDirection(from focusedWindowID: WindowID, direction: Direction) -> Result<MVPFocusResult, CommandError> {
        guard world.windows[focusedWindowID] != nil else {
            return .failure(.windowNotFound(focusedWindowID))
        }
        let currentLayout: Layout
        switch flattenedLayout(of: world) {
        case .success(let layout):
            currentLayout = layout
        case .failure(let unsatisfiable):
            return .failure(.layoutUnsatisfiable(unsatisfiable))
        }
        guard let targetWindowID = focusTarget(in: currentLayout, from: focusedWindowID, direction: direction) else {
            return .failure(.noNeighbor(direction))
        }
        guard let target = world.windows[targetWindowID] else {
            return .failure(.windowNotFound(targetWindowID))
        }
        return .success(MVPFocusResult(window: target, frame: currentLayout.tiled[targetWindowID] ?? target.frame))
    }

    func planFocusCycle(from focusedWindowID: WindowID?, direction: FocusCycleDirection) -> Result<MVPFocusResult, CommandError> {
        guard let targetWindowID = focusCycleTarget(
            windows: Array(world.windows.values),
            from: focusedWindowID,
            direction: direction
        ) else {
            return .failure(.windowNotFound(focusedWindowID ?? WindowID(raw: 0)))
        }
        guard let target = world.windows[targetWindowID] else {
            return .failure(.windowNotFound(targetWindowID))
        }
        let targetFrame: CGRect
        switch flattenedLayout(of: world) {
        case .success(let layout):
            targetFrame = layout.tiled[targetWindowID] ?? target.frame
        case .failure:
            targetFrame = target.frame
        }
        return .success(MVPFocusResult(window: target, frame: targetFrame))
    }

    func recordObservedConstraints(_ observations: [WindowID: WindowConstraints]) {
        for (windowID, constraints) in observations {
            world = WinMgrCore.recordObservedConstraints(constraints, for: windowID, in: world)
        }
    }

    func resetLayoutMemory() {
        switch apply(.resetLayout, to: world) {
        case .success(let resetWorld):
            world = resetWorld
        case .failure:
            world = resetTilingState(in: world)
        }
    }

    func restoreSnapshot() -> StoredWorld {
        storedWorld(from: world)
    }

    func commit(_ result: MVPCommandResult, appliedFrames: [WindowID: CGRect]) {
        world = worldByRecording(frames: appliedFrames, in: result.plannedWorld)
    }

    func recordAppliedFrames(_ frames: [WindowID: CGRect]) {
        guard !frames.isEmpty else { return }

        world = worldByRecording(frames: frames, in: world)
    }

    private func worldByRecording(frames: [WindowID: CGRect], in base: World) -> World {
        guard !frames.isEmpty else { return base }

        var windows = base.windows
        for (id, frame) in frames {
            guard let old = windows[id] else { continue }
            windows[id] = WindowMetadata(
                id: old.id,
                bundleID: old.bundleID,
                title: old.title,
                role: old.role,
                pid: old.pid,
                frame: frame,
                isResizable: old.isResizable,
                isMinimized: old.isMinimized
            )
        }

        return World(
            displays: base.displays,
            activeSpace: base.activeSpace,
            spaces: base.spaces,
            windows: windows,
            windowDisplay: base.windowDisplay,
            windowConstraints: base.windowConstraints,
            pendingRules: base.pendingRules,
            config: base.config
        )
    }

    private func flattenedLayout(of world: World) -> Result<Layout, UnsatisfiableLayout> {
        guard let activeSpace = world.activeSpace, let space = world.spaces[activeSpace] else {
            return .success(Layout(tiled: [:], floatingZOrder: [], hidden: []))
        }

        var tiled: [WindowID: CGRect] = [:]
        var floating: [WindowID] = []
        for displayID in space.displays.keys.sorted(by: { $0.raw < $1.raw }) {
            guard let display = world.displays[displayID] else { continue }
            let displayLayout: Layout
            switch solveLayout(
                spaceState: space,
                displayID: displayID,
                frame: display.visibleFrame,
                gaps: world.config.gaps,
                constraints: world.windowConstraints
            ) {
            case .solved(let layout, _):
                displayLayout = layout
            case .unsatisfiable(let unsatisfiable):
                return .failure(unsatisfiable)
            }
            tiled.merge(displayLayout.tiled) { _, next in next }
            floating.append(contentsOf: displayLayout.floatingZOrder)
        }

        return .success(Layout(tiled: tiled, floatingZOrder: floating, hidden: []))
    }
}
