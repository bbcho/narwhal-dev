import CoreGraphics

public func occupiedWindows(in node: Node) -> [WindowID] {
    slots(in: node).compactMap { slot in
        guard case .occupied(let windowID) = slot.occupancy else { return nil }
        return windowID
    }
}

public func slots(in node: Node) -> [TreeSlot] {
    slots(in: node, path: [])
}

private func slots(in node: Node, path: NodePath) -> [TreeSlot] {
    switch node {
    case .void:
        return [TreeSlot(path: path, occupancy: .empty)]
    case .leaf(let id):
        return [TreeSlot(path: path, occupancy: .occupied(id))]
    case .split(let split):
        return split.cells.enumerated().flatMap { index, cell in
            slots(in: cell.node, path: path + [index])
        }
    }
}

public func ejectFromTree(_ window: WindowID, _ node: Node) -> Node {
    clearWindowPreservingZones(window, from: node)
}

public func pruneTree(_ node: Node, keeping liveWindowIDs: Set<WindowID>) -> Node {
    switch node {
    case .void:
        return .void
    case .leaf(let id):
        return liveWindowIDs.contains(id) ? node : .void
    case .split(let split):
        let cells = split.cells.map { cell in
            makeCell(weight: cell.weight, node: pruneTree(cell.node, keeping: liveWindowIDs))
        }
        return .split(makeSplit(axis: split.axis, cells: cells))
    }
}

public func pushIntoTree(_ window: WindowID, _ direction: Direction, _ node: Node) -> Node {
    let treeWithoutWindow = clearWindowPreservingZones(window, from: node)
    return insertAtRootEdge(window, direction, treeWithoutWindow)
}

public func centerIntoTree(_ window: WindowID, _ node: Node) -> Node {
    let treeWithoutWindow = clearWindowPreservingZones(window, from: node)
    return insertAtCenter(window, treeWithoutWindow)
}

private func clearWindowPreservingZones(_ window: WindowID, from node: Node) -> Node {
    switch node {
    case .void:
        return .void
    case .leaf(let id):
        return id == window ? .void : node
    case .split(let split):
        let cells = split.cells.map { cell in
            makeCell(weight: cell.weight, node: clearWindowPreservingZones(window, from: cell.node))
        }
        return .split(makeSplit(axis: split.axis, cells: cells))
    }
}

private func insertAtCenter(_ window: WindowID, _ node: Node) -> Node {
    switch node {
    case .void:
        return centerRoot(center: .leaf(window))
    case .leaf:
        return centerRoot(center: insertIntoCenterStack(window, node))
    case .split(let split) where split.axis == .horizontal:
        let cells = normalizedCenterRootCells(from: split.cells)
        let center = cells[1]
        return .split(makeSplit(axis: .horizontal, cells: [
            cells[0],
            makeCell(weight: 2, node: insertIntoCenterStack(window, center.node)),
            cells[2]
        ]))
    case .split:
        return centerRoot(center: insertIntoCenterStack(window, node))
    }
}

private func centerRoot(center: Node) -> Node {
    .split(makeSplit(axis: .horizontal, cells: [
        makeCell(weight: 1, node: .void),
        makeCell(weight: 2, node: center),
        makeCell(weight: 1, node: .void)
    ]))
}

private func normalizedCenterRootCells(from cells: [Cell]) -> [Cell] {
    switch cells.count {
    case 2:
        return [
            makeCell(weight: 1, node: cells[0].node),
            makeCell(weight: 2, node: .void),
            makeCell(weight: 1, node: cells[1].node)
        ]
    case 3:
        return [
            makeCell(weight: 1, node: cells[0].node),
            makeCell(weight: 2, node: cells[1].node),
            makeCell(weight: 1, node: cells[2].node)
        ]
    default:
        let middleCells = Array(cells.dropFirst().dropLast())
        let middleNode = Node.split(makeSplit(axis: .horizontal, cells: middleCells))
        return [
            makeCell(weight: 1, node: cells[0].node),
            makeCell(weight: 2, node: middleNode),
            makeCell(weight: 1, node: cells[cells.count - 1].node)
        ]
    }
}

private func insertIntoCenterStack(_ window: WindowID, _ node: Node) -> Node {
    switch node {
    case .void:
        return .leaf(window)
    case .leaf:
        return .split(makeSplit(axis: .vertical, cells: [
            makeCell(weight: 1, node: node),
            makeCell(weight: 1, node: .leaf(window))
        ]))
    case .split(let split) where split.axis == .vertical:
        return .split(makeSplit(
            axis: .vertical,
            cells: split.cells + [makeCell(weight: 1, node: .leaf(window))]
        ))
    case .split:
        return .split(makeSplit(axis: .vertical, cells: [
            makeCell(weight: 1, node: node),
            makeCell(weight: 1, node: .leaf(window))
        ]))
    }
}

private func insertAtRootEdge(_ window: WindowID, _ direction: Direction, _ node: Node) -> Node {
    switch node {
    case .void:
        return edgeSplit(inserted: .leaf(window), existing: .void, direction: direction)
    case .leaf:
        return edgeSplit(inserted: .leaf(window), existing: node, direction: direction)
    case .split(let split):
        if direction.isVerticalEdge, split.axis == .vertical {
            return insertIntoVerticalRowRealm(window, direction, split)
        }

        guard split.axis == direction.layoutAxisForPush else {
            return insertIntoCenterLane(window, direction, split)
        }

        let targetIndex = direction.edgeInsertionIndex(count: split.cells.count)
        var cells = split.cells
        let target = cells[targetIndex]
        let replacement = insertIntoLane(window, direction, target.node, nextAxis: direction.splitLineAxis)
        cells[targetIndex] = makeCell(weight: target.weight, node: replacement)
        return .split(makeSplit(axis: split.axis, cells: cells))
    }
}

private func insertIntoVerticalRowRealm(_ window: WindowID, _ direction: Direction, _ split: Split) -> Node {
    var cells = split.cells
    let targetIndex = direction.edgeInsertionIndex(count: cells.count)
    let target = cells[targetIndex]
    cells[targetIndex] = makeCell(weight: target.weight, node: insertIntoHorizontalRow(window, target.node))
    return .split(makeSplit(axis: split.axis, cells: cells))
}

private func insertIntoHorizontalRow(_ window: WindowID, _ node: Node) -> Node {
    switch node {
    case .void:
        return .leaf(window)
    case .leaf:
        return .split(makeSplit(axis: .horizontal, cells: [
            makeCell(weight: 1, node: node),
            makeCell(weight: 1, node: .leaf(window))
        ]))
    case .split(let split) where split.axis == .horizontal:
        var cells = split.cells
        cells.insert(makeCell(weight: 1, node: .leaf(window)), at: max(0, cells.count - 1))
        return .split(makeSplit(axis: split.axis, cells: cells))
    case .split:
        return insertIntoLane(window, .right, node, nextAxis: .horizontal)
    }
}

private func insertIntoCenterLane(_ window: WindowID, _ direction: Direction, _ split: Split) -> Node {
    var cells = split.cells
    let targetIndex = centerLaneIndex(in: &cells)
    let target = cells[targetIndex]
    let replacement = insertAtRootEdge(window, direction, target.node)
    cells[targetIndex] = makeCell(weight: target.weight, node: replacement)
    return .split(makeSplit(axis: split.axis, cells: cells))
}

private func centerLaneIndex(in cells: inout [Cell]) -> Int {
    if cells.count == 2 {
        cells.insert(makeCell(weight: 1, node: .void), at: 1)
        return 1
    }
    return cells.count / 2
}

private func insertIntoLane(_ window: WindowID, _ direction: Direction, _ node: Node, nextAxis: Axis) -> Node {
    switch node {
    case .void:
        return .leaf(window)
    case .leaf:
        return splitLaneLeaf(inserted: .leaf(window), existing: node, direction: direction, axis: nextAxis)
    case .split(let split):
        let targetIndex = direction.centerFacingIndex(axis: split.axis, count: split.cells.count)
        var cells = split.cells
        let target = cells[targetIndex]
        cells[targetIndex] = makeCell(
            weight: target.weight,
            node: insertIntoLane(window, direction, target.node, nextAxis: split.axis.toggled)
        )
        return .split(makeSplit(axis: split.axis, cells: cells))
    }
}

private func edgeSplit(inserted: Node, existing: Node, direction: Direction) -> Node {
    let cells: [Cell]
    switch direction {
    case .left, .up:
        cells = [
            makeCell(weight: 1, node: inserted),
            makeCell(weight: 1, node: existing)
        ]
    case .right, .down:
        cells = [
            makeCell(weight: 1, node: existing),
            makeCell(weight: 1, node: inserted)
        ]
    }
    return .split(makeSplit(axis: direction.layoutAxisForPush, cells: cells))
}

private func splitLaneLeaf(inserted: Node, existing: Node, direction: Direction, axis: Axis) -> Node {
    let cells: [Cell]
    switch (axis, direction) {
    case (.horizontal, .right), (.vertical, .down):
        cells = [
            makeCell(weight: 1, node: inserted),
            makeCell(weight: 1, node: existing)
        ]
    default:
        cells = [
            makeCell(weight: 1, node: existing),
            makeCell(weight: 1, node: inserted)
        ]
    }
    return .split(makeSplit(axis: axis, cells: cells))
}

private extension Direction {
    var isVerticalEdge: Bool {
        switch self {
        case .up, .down:
            return true
        case .left, .right:
            return false
        }
    }

    func edgeInsertionIndex(count: Int) -> Int {
        switch self {
        case .left, .up:
            return 0
        case .right, .down:
            return count - 1
        }
    }

    func centerFacingIndex(axis: Axis, count: Int) -> Int {
        switch (self, axis) {
        case (.left, .horizontal), (.up, .vertical):
            return count - 1
        case (.right, .horizontal), (.down, .vertical):
            return 0
        case (.left, .vertical), (.right, .vertical), (.up, .horizontal), (.down, .horizontal):
            return count - 1
        }
    }
}

private extension Axis {
    var toggled: Axis {
        switch self {
        case .horizontal:
            return .vertical
        case .vertical:
            return .horizontal
        }
    }
}

private func makeCell(weight: Double, node: Node) -> Cell {
    switch Cell.create(weight: weight, node: node) {
    case .success(let cell):
        return cell
    case .failure(let error):
        preconditionFailure("Invalid Cell in tree operation: \(error)")
    }
}

private func makeSplit(axis: Axis, cells: [Cell]) -> Split {
    switch Split.create(axis: axis, cells: cells) {
    case .success(let split):
        return split
    case .failure(let error):
        preconditionFailure("Invalid Split in tree operation: \(error)")
    }
}
