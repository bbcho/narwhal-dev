import CoreGraphics

public func layout(spaceState: SpaceState, displayID: DisplayID, frame: CGRect, gaps: Gaps) -> Layout {
    guard let displayState = spaceState.displays[displayID] else {
        return Layout(tiled: [:], floatingZOrder: [], hidden: [])
    }

    let usableFrame = applyOuterGaps(gaps.outer, to: frame)
    let tiled = framesByWindow(in: displayState.tree, frame: usableFrame, innerGap: gaps.inner)
    return Layout(tiled: tiled, floatingZOrder: sanitizedFloatingIDs(in: displayState), hidden: [])
}

public func diff(old: Layout, new: Layout) -> LayoutDelta {
    let moves = new.tiled.filter { window, frame in
        old.tiled[window] != frame
    }
    let oldWindows = Set(old.tiled.keys)
    let newWindows = Set(new.tiled.keys)
    return LayoutDelta(
        moves: moves,
        raises: [],
        hides: oldWindows.subtracting(newWindows),
        shows: newWindows.subtracting(oldWindows)
    )
}

public func flattenedLayout(of world: World) -> Result<Layout, UnsatisfiableLayout> {
    let workspaceKeys = activeWorkspaceKeys(in: world)
    guard !workspaceKeys.isEmpty else {
        return .success(Layout(tiled: [:], floatingZOrder: [], hidden: []))
    }

    return workspaceKeys
        .reduce(Result<FlattenedLayoutAccumulator, UnsatisfiableLayout>.success(.empty)) { result, key in
            result.flatMap { accumulator in
                activeWorkspaceLayout(for: key, in: world)
                    .map { accumulator.adding($0) }
            }
        }
        .map(\.layout)
}

public func workspaceLayout(
    for key: WorkspaceKey,
    in world: World
) -> Result<Layout, UnsatisfiableLayout> {
    guard let display = world.displays[key.displayID],
          let space = world.spaces[key.spaceID]
    else {
        return .success(Layout(tiled: [:], floatingZOrder: [], hidden: []))
    }

    switch solveLayout(
        spaceState: space,
        displayID: key.displayID,
        frame: display.visibleFrame,
        gaps: world.config.gaps,
        constraints: world.windowConstraints
    ) {
    case .solved(let layout, _):
        return .success(layout)
    case .unsatisfiable(let unsatisfiable):
        return .failure(unsatisfiable)
    }
}

public func tiledBorderTargets(of world: World) -> Result<[FocusBorderTarget], UnsatisfiableLayout> {
    flattenedLayout(of: world)
        .map { layout in
            layout.tiled
                .compactMap { windowID, layoutFrame -> FocusBorderTarget? in
                    guard let window = world.windows[windowID] else { return nil }
                    let frame = window.frame.narwhalIsFinitePositive ? window.frame : layoutFrame
                    return FocusBorderTarget(window: window, frame: frame)
                }
                .sorted { $0.windowID.raw < $1.windowID.raw }
        }
}

public func pendingTileRuleApplications(in world: World) -> Result<[(WindowID, ZoneID)], UnsatisfiableLayout> {
    flattenedLayout(of: world)
        .map { layout in
            let activeWindowIDs = Set(layout.tiled.keys).union(layout.floatingZOrder)
            return world.pendingRules
                .compactMap { windowID, action -> (WindowID, ZoneID)? in
                    guard activeWindowIDs.contains(windowID),
                          case .tileToZone(let zoneID) = action
                    else { return nil }
                    return (windowID, zoneID)
                }
                .sorted { $0.0.raw < $1.0.raw }
        }
}

public struct PendingTileRuleApplicationPlan: Equatable, Sendable {
    public let world: World
    public let focusedWindowID: WindowID?

    public init(world: World, focusedWindowID: WindowID?) {
        self.world = world
        self.focusedWindowID = focusedWindowID
    }
}

public func applyingPendingTileRules(
    in world: World
) -> Result<PendingTileRuleApplicationPlan?, CommandError> {
    pendingTileRuleApplications(in: world)
        .mapError(CommandError.layoutUnsatisfiable)
        .flatMap { pending in
            guard !pending.isEmpty else { return .success(nil) }

            return pending.reduce(
                Result<PendingTileRuleApplicationAccumulator, CommandError>.success(.initial(world))
            ) { partial, application in
                partial.flatMap { accumulator in
                    accumulator.applying(windowID: application.0, zoneID: application.1)
                }
            }
            .map { accumulator in
                guard accumulator.world != world else { return nil }
                return PendingTileRuleApplicationPlan(
                    world: accumulator.world,
                    focusedWindowID: accumulator.focusedWindowID
                )
            }
        }
}

private func framesByWindow(in node: Node, frame: CGRect, innerGap: Double) -> [WindowID: CGRect] {
    switch node {
    case .void:
        return [:]
    case .leaf(let id):
        return [id: frame.insetBy(dx: innerGap / 2, dy: innerGap / 2).standardized]
    case .split(let split):
        let rects = splitFrames(frame, axis: split.axis, weights: split.cells.map(\.weight))
        return zip(split.cells, rects).reduce([WindowID: CGRect]()) { result, pair in
            result.merging(
                framesByWindow(in: pair.0.node, frame: pair.1, innerGap: innerGap)
            ) { _, next in next }
        }
    }
}

private struct FlattenedLayoutAccumulator {
    let tiled: [WindowID: CGRect]
    let floatingZOrder: [WindowID]

    static let empty = FlattenedLayoutAccumulator(tiled: [:], floatingZOrder: [])

    var layout: Layout {
        Layout(tiled: tiled, floatingZOrder: floatingZOrder, hidden: [])
    }

    func adding(_ layout: Layout) -> FlattenedLayoutAccumulator {
        FlattenedLayoutAccumulator(
            tiled: tiled.merging(layout.tiled) { _, next in next },
            floatingZOrder: floatingZOrder + layout.floatingZOrder
        )
    }
}

private func activeWorkspaceLayout(
    for key: WorkspaceKey,
    in world: World
) -> Result<Layout, UnsatisfiableLayout> {
    workspaceLayout(for: key, in: world)
}

private struct PendingTileRuleApplicationAccumulator {
    let world: World
    let focusedWindowID: WindowID?

    static func initial(_ world: World) -> PendingTileRuleApplicationAccumulator {
        PendingTileRuleApplicationAccumulator(world: world, focusedWindowID: nil)
    }

    func applying(windowID: WindowID, zoneID: ZoneID) -> Result<PendingTileRuleApplicationAccumulator, CommandError> {
        guard let displayID = world.windowDisplay[windowID] else {
            return .success(self)
        }

        switch apply(.dropAtZone(windowID, displayID, zoneID), to: world) {
        case .success(let next):
            return .success(PendingTileRuleApplicationAccumulator(
                world: next.clearingPendingRule(for: windowID),
                focusedWindowID: windowID
            ))
        case .failure(.zoneNotFound):
            return .success(PendingTileRuleApplicationAccumulator(
                world: world.clearingPendingRule(for: windowID),
                focusedWindowID: focusedWindowID
            ))
        case .failure(let error):
            return .failure(error)
        }
    }
}

private extension World {
    func clearingPendingRule(for windowID: WindowID) -> World {
        return World(
            displays: displays,
            activeSpace: activeSpace,
            activeSpaceByDisplay: activeSpaceByDisplay,
            spaces: spaces,
            windows: windows,
            windowDisplay: windowDisplay,
            windowSpace: windowSpace,
            observedVisibleWindows: observedVisibleWindows,
            windowConstraints: windowConstraints,
            pendingRules: pendingRules.filter { $0.key != windowID },
            config: config
        )
    }
}
