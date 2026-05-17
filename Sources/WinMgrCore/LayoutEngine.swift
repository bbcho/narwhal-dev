import CoreGraphics

public func layout(spaceState: SpaceState, displayID: DisplayID, frame: CGRect, gaps: Gaps) -> Layout {
    guard let displayState = spaceState.displays[displayID] else {
        return Layout(tiled: [:], floatingZOrder: [], hidden: [])
    }

    let usableFrame = applyOuterGaps(gaps.outer, to: frame)
    let tiled = framesByWindow(in: displayState.tree, frame: usableFrame, innerGap: gaps.inner)
    return Layout(tiled: tiled, floatingZOrder: displayState.floating, hidden: [])
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
