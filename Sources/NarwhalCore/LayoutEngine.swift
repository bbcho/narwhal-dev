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

public func frameWriteOrder(for layout: Layout, focused focusedWindowID: WindowID?) -> [WindowID] {
    let ordered = layout.tiled.keys.sorted { $0.raw < $1.raw }
    guard let focusedWindowID, ordered.contains(focusedWindowID) else {
        return ordered
    }
    return ordered.filter { $0 != focusedWindowID } + [focusedWindowID]
}

public func flattenedLayout(of world: World) -> Result<Layout, UnsatisfiableLayout> {
    let workspaceKeys = activeWorkspaceKeys(in: world)
    guard !workspaceKeys.isEmpty else {
        return .success(Layout(tiled: [:], floatingZOrder: [], hidden: []))
    }

    var tiled: [WindowID: CGRect] = [:]
    var floating: [WindowID] = []
    for key in workspaceKeys {
        guard let display = world.displays[key.displayID],
              let space = world.spaces[key.spaceID]
        else { continue }
        let displayLayout: Layout
        switch solveLayout(
            spaceState: space,
            displayID: key.displayID,
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

public func tiledBorderTargets(of world: World) -> Result<[FocusBorderTarget], UnsatisfiableLayout> {
    switch flattenedLayout(of: world) {
    case .success(let layout):
        let targets = layout.tiled
            .compactMap { windowID, layoutFrame -> FocusBorderTarget? in
                guard let window = world.windows[windowID] else { return nil }
                let frame = window.frame.isFinitePositive ? window.frame : layoutFrame
                return FocusBorderTarget(window: window, frame: frame)
            }
            .sorted { $0.windowID.raw < $1.windowID.raw }
        return .success(targets)
    case .failure(let unsatisfiable):
        return .failure(unsatisfiable)
    }
}

public func pendingTileRuleApplications(in world: World) -> Result<[(WindowID, ZoneID)], UnsatisfiableLayout> {
    switch flattenedLayout(of: world) {
    case .success(let layout):
        let activeWindowIDs = Set(layout.tiled.keys).union(layout.floatingZOrder)
        let pending = world.pendingRules
            .compactMap { windowID, action -> (WindowID, ZoneID)? in
                guard activeWindowIDs.contains(windowID),
                      case .tileToZone(let zoneID) = action
                else { return nil }
                return (windowID, zoneID)
            }
            .sorted { $0.0.raw < $1.0.raw }
        return .success(pending)
    case .failure(let unsatisfiable):
        return .failure(unsatisfiable)
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
        return zip(split.cells, rects).reduce(into: [:]) { result, pair in
            let childFrames = framesByWindow(in: pair.0.node, frame: pair.1, innerGap: innerGap)
            result.merge(childFrames) { _, next in next }
        }
    }
}

private func splitFrames(_ frame: CGRect, axis: Axis, weights: [Double]) -> [CGRect] {
    let total = weights.reduce(0, +)
    guard total > 0 else { return [] }

    var offset: CGFloat = 0
    return weights.enumerated().map { index, weight in
        let isLast = index == weights.count - 1
        switch axis {
        case .horizontal:
            let width = isLast ? frame.width - offset : frame.width * CGFloat(weight / total)
            defer { offset += width }
            return CGRect(x: frame.minX + offset, y: frame.minY, width: width, height: frame.height)
        case .vertical:
            let height = isLast ? frame.height - offset : frame.height * CGFloat(weight / total)
            defer { offset += height }
            return CGRect(x: frame.minX, y: frame.minY + offset, width: frame.width, height: height)
        }
    }
}

private func applyOuterGaps(_ gaps: Insets, to frame: CGRect) -> CGRect {
    CGRect(
        x: frame.minX + gaps.left,
        y: frame.minY + gaps.top,
        width: max(0, frame.width - gaps.left - gaps.right),
        height: max(0, frame.height - gaps.top - gaps.bottom)
    )
}

private extension CGRect {
    var isFinitePositive: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
