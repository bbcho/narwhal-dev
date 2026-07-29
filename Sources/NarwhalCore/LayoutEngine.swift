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

public struct InnerGapViolation: Equatable, Sendable {
    public let axis: Axis
    public let before: WindowID
    public let after: WindowID
    public let expected: Double
    public let actual: Double

    public init(axis: Axis, before: WindowID, after: WindowID, expected: Double, actual: Double) {
        self.axis = axis
        self.before = before
        self.after = after
        self.expected = expected
        self.actual = actual
    }
}

public struct SnappedFrameGapConflict: Error, Equatable, Sendable {
    public let axis: Axis
    public let windows: [WindowID]

    public init(axis: Axis, windows: [WindowID]) {
        self.axis = axis
        self.windows = windows
    }
}

public func reflowSnappedFrames(
    planned: [WindowID: CGRect],
    actual: [WindowID: CGRect],
    innerGap: Double,
    anchoredWindowIDs: Set<WindowID> = [],
    tolerance: Double = Double(configuredGapTolerance)
) -> Result<[WindowID: CGRect], SnappedFrameGapConflict> {
    let gap = CGFloat(max(0, innerGap))
    let tolerance = CGFloat(max(0, tolerance))
    let relations = plannedGapRelations(planned: planned, gap: gap, tolerance: tolerance)
    var reflowed = actual

    for axis in Axis.allCases {
        switch reflowSnappedFrames(
            reflowed,
            planned: planned,
            relations: relations.filter { $0.axis == axis },
            axis: axis,
            gap: gap,
            anchoredWindowIDs: anchoredWindowIDs,
            tolerance: tolerance
        ) {
        case .success(let frames):
            reflowed = frames
        case .failure(let conflict):
            return .failure(conflict)
        }
    }

    if let violation = innerGapViolations(
        planned: planned,
        actual: reflowed,
        innerGap: innerGap,
        tolerance: Double(tolerance)
    ).first {
        return .failure(SnappedFrameGapConflict(
            axis: violation.axis,
            windows: [violation.before, violation.after].sorted { $0.raw < $1.raw }
        ))
    }
    return .success(reflowed)
}

public func reflowSnappedFramesBestEffort(
    planned: [WindowID: CGRect],
    actual: [WindowID: CGRect],
    innerGap: Double,
    anchoredWindowIDs: Set<WindowID> = [],
    tolerance: Double = Double(configuredGapTolerance)
) -> Result<[WindowID: CGRect], SnappedFrameGapConflict> {
    let gap = CGFloat(max(0, innerGap))
    let tolerance = CGFloat(max(0, tolerance))
    let relations = plannedGapRelations(planned: planned, gap: gap, tolerance: tolerance)
    var reflowed = actual

    for axis in Axis.allCases {
        switch reflowSnappedFramesBestEffort(
            reflowed,
            planned: planned,
            relations: relations.filter { $0.axis == axis },
            axis: axis,
            gap: gap,
            anchoredWindowIDs: anchoredWindowIDs,
            tolerance: tolerance
        ) {
        case .success(let frames):
            reflowed = frames
        case .failure(let conflict):
            return .failure(conflict)
        }
    }
    return .success(reflowed)
}

public func innerGapViolations(
    planned: [WindowID: CGRect],
    actual: [WindowID: CGRect],
    innerGap: Double,
    tolerance: Double = Double(configuredGapTolerance)
) -> [InnerGapViolation] {
    let gap = CGFloat(max(0, innerGap))
    let tolerance = CGFloat(max(0, tolerance))
    return plannedGapRelations(planned: planned, gap: gap, tolerance: tolerance).compactMap { relation in
        guard let before = actual[relation.before], let after = actual[relation.after] else { return nil }
        let actualGap = relation.axis == .horizontal
            ? after.minX - before.maxX
            : after.minY - before.maxY
        guard abs(actualGap - gap) > tolerance else { return nil }
        return InnerGapViolation(
            axis: relation.axis,
            before: relation.before,
            after: relation.after,
            expected: Double(gap),
            actual: Double(actualGap)
        )
    }
}

private struct PlannedGapRelation {
    let axis: Axis
    let before: WindowID
    let after: WindowID
}

private struct SnappedFrameOffset {
    let windowID: WindowID
    let delta: CGFloat
}

private func plannedGapRelations(
    planned: [WindowID: CGRect],
    gap: CGFloat,
    tolerance: CGFloat
) -> [PlannedGapRelation] {
    let ids = planned.keys.sorted { $0.raw < $1.raw }
    return ids.indices.flatMap { firstIndex in
        ids.indices.dropFirst(firstIndex + 1).compactMap { secondIndex in
            let firstID = ids[firstIndex]
            let secondID = ids[secondIndex]
            guard let first = planned[firstID], let second = planned[secondID] else { return nil }

            if overlap(first.minY, first.maxY, second.minY, second.maxY) > tolerance {
                if abs(second.minX - first.maxX - gap) <= tolerance {
                    return PlannedGapRelation(axis: .horizontal, before: firstID, after: secondID)
                }
                if abs(first.minX - second.maxX - gap) <= tolerance {
                    return PlannedGapRelation(axis: .horizontal, before: secondID, after: firstID)
                }
            }
            if overlap(first.minX, first.maxX, second.minX, second.maxX) > tolerance {
                if abs(second.minY - first.maxY - gap) <= tolerance {
                    return PlannedGapRelation(axis: .vertical, before: firstID, after: secondID)
                }
                if abs(first.minY - second.maxY - gap) <= tolerance {
                    return PlannedGapRelation(axis: .vertical, before: secondID, after: firstID)
                }
            }
            return nil
        }
    }
}

private func reflowSnappedFrames(
    _ actual: [WindowID: CGRect],
    planned: [WindowID: CGRect],
    relations: [PlannedGapRelation],
    axis: Axis,
    gap: CGFloat,
    anchoredWindowIDs: Set<WindowID>,
    tolerance: CGFloat
) -> Result<[WindowID: CGRect], SnappedFrameGapConflict> {
    var graph: [WindowID: [SnappedFrameOffset]] = [:]
    for relation in relations {
        guard let before = actual[relation.before], actual[relation.after] != nil else { continue }
        let delta = before.length(on: axis) + gap
        graph[relation.before, default: []].append(SnappedFrameOffset(windowID: relation.after, delta: delta))
        graph[relation.after, default: []].append(SnappedFrameOffset(windowID: relation.before, delta: -delta))
    }

    var result = actual
    var visited = Set<WindowID>()
    for seed in graph.keys.sorted(by: { $0.raw < $1.raw }) where !visited.contains(seed) {
        let component = connectedWindows(from: seed, graph: graph)
        visited.formUnion(component)
        guard let origins = relativeOrigins(seed: seed, graph: graph, tolerance: tolerance) else {
            return .failure(SnappedFrameGapConflict(
                axis: axis,
                windows: component.sorted { $0.raw < $1.raw }
            ))
        }
        guard let shift = snappedFrameComponentShift(
            component,
            relativeOrigins: origins,
            planned: planned,
            actual: actual,
            axis: axis,
            anchoredWindowIDs: anchoredWindowIDs,
            tolerance: tolerance
        ) else {
            return .failure(SnappedFrameGapConflict(
                axis: axis,
                windows: component.sorted { $0.raw < $1.raw }
            ))
        }
        for windowID in component {
            guard let frame = result[windowID], let relativeOrigin = origins[windowID] else { continue }
            result[windowID] = frame.settingOrigin(relativeOrigin + shift, on: axis)
        }
    }
    return .success(result)
}

private func reflowSnappedFramesBestEffort(
    _ actual: [WindowID: CGRect],
    planned: [WindowID: CGRect],
    relations: [PlannedGapRelation],
    axis: Axis,
    gap: CGFloat,
    anchoredWindowIDs: Set<WindowID>,
    tolerance: CGFloat
) -> Result<[WindowID: CGRect], SnappedFrameGapConflict> {
    var graph: [WindowID: [SnappedFrameOffset]] = [:]
    for relation in relations {
        guard let before = actual[relation.before], actual[relation.after] != nil else { continue }
        let delta = before.length(on: axis) + gap
        graph[relation.before, default: []].append(SnappedFrameOffset(windowID: relation.after, delta: delta))
        graph[relation.after, default: []].append(SnappedFrameOffset(windowID: relation.before, delta: -delta))
    }

    var result = actual
    var visited = Set<WindowID>()
    for seed in graph.keys.sorted(by: { $0.raw < $1.raw }) where !visited.contains(seed) {
        let component = connectedWindows(from: seed, graph: graph)
        visited.formUnion(component)
        let ordered = component.sorted { $0.raw < $1.raw }
        var origins = Dictionary(uniqueKeysWithValues: ordered.compactMap { windowID in
            actual[windowID].map { (windowID, $0.origin(on: axis)) }
        })
        let anchors = component.intersection(anchoredWindowIDs)

        for iteration in 0..<128 {
            var maximumChange: CGFloat = 0
            let sweep = iteration.isMultiple(of: 2) ? ordered : Array(ordered.reversed())
            for windowID in sweep where !anchors.contains(windowID) {
                guard let frame = actual[windowID],
                      let current = origins[windowID]
                else {
                    continue
                }
                let edges = graph[windowID] ?? []
                let candidates = edges.compactMap { edge -> CGFloat? in
                    origins[edge.windowID].map { $0 - edge.delta }
                }
                guard !candidates.isEmpty else { continue }

                var lowerBound = -CGFloat.infinity
                var upperBound = CGFloat.infinity
                for edge in edges {
                    guard let neighborOrigin = origins[edge.windowID],
                          let neighborFrame = actual[edge.windowID]
                    else {
                        continue
                    }
                    if edge.delta >= 0 {
                        upperBound = min(upperBound, neighborOrigin - frame.length(on: axis))
                    } else {
                        lowerBound = max(
                            lowerBound,
                            neighborOrigin + neighborFrame.length(on: axis)
                        )
                    }
                }
                guard lowerBound <= upperBound + tolerance else {
                    return .failure(SnappedFrameGapConflict(axis: axis, windows: ordered))
                }

                let desired = candidates.reduce(0, +) / CGFloat(candidates.count)
                let replacement = min(max(desired, lowerBound), upperBound)
                origins[windowID] = replacement
                maximumChange = max(maximumChange, abs(replacement - current))
            }

            if anchors.isEmpty {
                guard centerSnappedFrameComponent(
                    component,
                    origins: &origins,
                    planned: planned,
                    actual: actual,
                    axis: axis,
                    tolerance: tolerance
                ) else {
                    return .failure(SnappedFrameGapConflict(axis: axis, windows: ordered))
                }
            }
            if maximumChange <= tolerance / 10 {
                break
            }
        }

        guard componentFitsPlannedBounds(
            component,
            relativeOrigins: origins,
            shift: 0,
            planned: planned,
            actual: actual,
            axis: axis,
            tolerance: tolerance
        ) else {
            return .failure(SnappedFrameGapConflict(axis: axis, windows: ordered))
        }
        for relation in relations where component.contains(relation.before) && component.contains(relation.after) {
            guard let beforeOrigin = origins[relation.before],
                  let beforeFrame = actual[relation.before],
                  let afterOrigin = origins[relation.after],
                  afterOrigin - beforeOrigin - beforeFrame.length(on: axis) >= -tolerance
            else {
                return .failure(SnappedFrameGapConflict(axis: axis, windows: ordered))
            }
        }
        for windowID in component {
            guard let frame = result[windowID], let origin = origins[windowID] else { continue }
            result[windowID] = frame.settingOrigin(origin, on: axis)
        }
    }
    return .success(result)
}

private func centerSnappedFrameComponent(
    _ component: Set<WindowID>,
    origins: inout [WindowID: CGFloat],
    planned: [WindowID: CGRect],
    actual: [WindowID: CGRect],
    axis: Axis,
    tolerance: CGFloat
) -> Bool {
    guard let plannedMin = component.compactMap({ planned[$0]?.minimum(on: axis) }).min(),
          let plannedMax = component.compactMap({ planned[$0]?.maximum(on: axis) }).max(),
          let actualMin = component.compactMap({ origins[$0] }).min(),
          let actualMax = component.compactMap({ windowID -> CGFloat? in
              guard let origin = origins[windowID], let frame = actual[windowID] else { return nil }
              return origin + frame.length(on: axis)
          }).max()
    else {
        return false
    }
    let requiredLength = actualMax - actualMin
    let availableLength = plannedMax - plannedMin
    guard requiredLength <= availableLength + tolerance else { return false }
    let shift = plannedMin + (availableLength - requiredLength) / 2 - actualMin
    for windowID in component where origins[windowID] != nil {
        origins[windowID, default: 0] += shift
    }
    return true
}

private func connectedWindows(
    from seed: WindowID,
    graph: [WindowID: [SnappedFrameOffset]]
) -> Set<WindowID> {
    var component: Set<WindowID> = [seed]
    var queue = [seed]
    var index = 0
    while index < queue.count {
        let current = queue[index]
        index += 1
        for edge in graph[current] ?? [] where component.insert(edge.windowID).inserted {
            queue.append(edge.windowID)
        }
    }
    return component
}

private func relativeOrigins(
    seed: WindowID,
    graph: [WindowID: [SnappedFrameOffset]],
    tolerance: CGFloat
) -> [WindowID: CGFloat]? {
    var origins: [WindowID: CGFloat] = [seed: 0]
    var queue = [seed]
    var index = 0
    while index < queue.count {
        let current = queue[index]
        index += 1
        guard let currentOrigin = origins[current] else { continue }
        for edge in (graph[current] ?? []).sorted(by: { $0.windowID.raw < $1.windowID.raw }) {
            let candidate = currentOrigin + edge.delta
            if let existing = origins[edge.windowID] {
                guard abs(existing - candidate) <= tolerance else {
                    return nil
                }
            } else {
                origins[edge.windowID] = candidate
                queue.append(edge.windowID)
            }
        }
    }
    return origins
}

private func snappedFrameComponentShift(
    _ component: Set<WindowID>,
    relativeOrigins: [WindowID: CGFloat],
    planned: [WindowID: CGRect],
    actual: [WindowID: CGRect],
    axis: Axis,
    anchoredWindowIDs: Set<WindowID>,
    tolerance: CGFloat
) -> CGFloat? {
    let anchors = component.intersection(anchoredWindowIDs).sorted { $0.raw < $1.raw }
    if let firstAnchor = anchors.first,
       let anchorFrame = actual[firstAnchor],
       let anchorOrigin = relativeOrigins[firstAnchor] {
        let shift = anchorFrame.origin(on: axis) - anchorOrigin
        guard anchors.dropFirst().allSatisfy({ windowID in
            guard let frame = actual[windowID], let origin = relativeOrigins[windowID] else { return false }
            return abs(frame.origin(on: axis) - origin - shift) <= tolerance
        }) else {
            return nil
        }
        return componentFitsPlannedBounds(
            component,
            relativeOrigins: relativeOrigins,
            shift: shift,
            planned: planned,
            actual: actual,
            axis: axis,
            tolerance: tolerance
        ) ? shift : nil
    }

    guard let plannedMin = component.compactMap({ planned[$0]?.minimum(on: axis) }).min(),
          let plannedMax = component.compactMap({ planned[$0]?.maximum(on: axis) }).max(),
          let relativeMin = component.compactMap({ relativeOrigins[$0] }).min(),
          let relativeMax = component.compactMap({ windowID -> CGFloat? in
              guard let origin = relativeOrigins[windowID], let frame = actual[windowID] else { return nil }
              return origin + frame.length(on: axis)
          }).max()
    else {
        return nil
    }
    let plannedLength = plannedMax - plannedMin
    let requiredLength = relativeMax - relativeMin
    guard requiredLength <= plannedLength + tolerance else { return nil }
    return plannedMin + (plannedLength - requiredLength) / 2 - relativeMin
}

private func componentFitsPlannedBounds(
    _ component: Set<WindowID>,
    relativeOrigins: [WindowID: CGFloat],
    shift: CGFloat,
    planned: [WindowID: CGRect],
    actual: [WindowID: CGRect],
    axis: Axis,
    tolerance: CGFloat
) -> Bool {
    guard let plannedMin = component.compactMap({ planned[$0]?.minimum(on: axis) }).min(),
          let plannedMax = component.compactMap({ planned[$0]?.maximum(on: axis) }).max(),
          let actualMin = component.compactMap({ relativeOrigins[$0].map { $0 + shift } }).min(),
          let actualMax = component.compactMap({ windowID -> CGFloat? in
              guard let origin = relativeOrigins[windowID], let frame = actual[windowID] else { return nil }
              return origin + shift + frame.length(on: axis)
          }).max()
    else {
        return false
    }
    return actualMin >= plannedMin - tolerance && actualMax <= plannedMax + tolerance
}

private func overlap(_ firstMin: CGFloat, _ firstMax: CGFloat, _ secondMin: CGFloat, _ secondMax: CGFloat) -> CGFloat {
    max(0, min(firstMax, secondMax) - max(firstMin, secondMin))
}

private extension CGRect {
    func minimum(on axis: Axis) -> CGFloat {
        axis == .horizontal ? minX : minY
    }

    func maximum(on axis: Axis) -> CGFloat {
        axis == .horizontal ? maxX : maxY
    }

    func length(on axis: Axis) -> CGFloat {
        axis == .horizontal ? width : height
    }

    func origin(on axis: Axis) -> CGFloat {
        axis == .horizontal ? minX : minY
    }

    func settingOrigin(_ value: CGFloat, on axis: Axis) -> CGRect {
        switch axis {
        case .horizontal:
            return CGRect(x: value, y: minY, width: width, height: height)
        case .vertical:
            return CGRect(x: minX, y: value, width: width, height: height)
        }
    }
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

public func spaceLayout(
    for spaceID: SpaceID,
    in world: World
) -> Result<Layout, UnsatisfiableLayout> {
    guard let space = world.spaces[spaceID] else {
        return .success(Layout(tiled: [:], floatingZOrder: [], hidden: []))
    }
    return space.displays.keys.sorted(by: { $0.raw < $1.raw }).reduce(
        Result<Layout, UnsatisfiableLayout>.success(Layout(tiled: [:], floatingZOrder: [], hidden: []))
    ) { result, displayID in
        result.flatMap { accumulated in
            workspaceLayout(for: WorkspaceKey(displayID: displayID, spaceID: spaceID), in: world).map { current in
                Layout(
                    tiled: accumulated.tiled.merging(current.tiled) { _, replacement in replacement },
                    floatingZOrder: accumulated.floatingZOrder + current.floatingZOrder,
                    hidden: accumulated.hidden.union(current.hidden)
                )
            }
        }
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
