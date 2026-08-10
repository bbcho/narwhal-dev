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
    let treeWithoutWindow = removeWindowForRetile(window, from: node)
    return insertAtRootEdge(window, direction, treeWithoutWindow)
}

public func centerIntoTree(_ window: WindowID, _ node: Node) -> Node {
    let treeWithoutWindow = removeWindowForRetile(window, from: node)
    return insertAtCenter(window, treeWithoutWindow)
}

public func quarterIntoTree(_ window: WindowID, _ corner: Corner, _ node: Node) -> Node {
    let treeWithoutWindow = removeWindowForRetile(window, from: node)
    return insertAtRootCorner(window, corner, treeWithoutWindow)
}

public func swapWindowsInTree(_ first: WindowID, _ second: WindowID, _ node: Node) -> Node {
    guard first != second else { return node }

    switch node {
    case .void:
        return .void
    case .leaf(let id) where id == first:
        return .leaf(second)
    case .leaf(let id) where id == second:
        return .leaf(first)
    case .leaf:
        return node
    case .split(let split):
        let cells = split.cells.map { cell in
            makeCell(weight: cell.weight, node: swapWindowsInTree(first, second, cell.node))
        }
        return .split(makeSplit(axis: split.axis, cells: cells))
    }
}

public func balanceTree(_ node: Node) -> Node {
    switch node {
    case .void, .leaf:
        return node
    case .split(let split):
        let cells = split.cells.map { cell in
            makeCell(weight: 1, node: balanceTree(cell.node))
        }
        return .split(makeSplit(axis: split.axis, cells: cells))
    }
}

public enum TreeResizeError: Error, Equatable, Sendable {
    case windowNotFound(WindowID)
    case noNeighbor(Direction)
    case nonFiniteDelta
    case nonPositiveWeight
}

public enum TreeSubtreeInsertError: Error, Equatable, Sendable {
    case pathNotFound(NodePath)
}

public func resizeSplitInTree(
    _ window: WindowID,
    _ direction: Direction,
    delta: Double,
    _ node: Node
) -> Result<Node, TreeResizeError> {
    guard delta.isFinite else { return .failure(.nonFiniteDelta) }
    guard let path = pathToWindow(window, in: node, parentPath: []) else {
        return .failure(.windowNotFound(window))
    }
    guard let target = resizeTarget(in: path, direction: direction) else {
        return .failure(.noNeighbor(direction))
    }
    return resizeSplit(
        at: target.parentPath,
        childIndex: target.childIndex,
        neighborIndex: target.neighborIndex,
        delta: delta,
        in: node
    )
}

public func insertIntoSubtree(
    _ window: WindowID,
    path: NodePath,
    _ node: Node
) -> Result<Node, TreeSubtreeInsertError> {
    let treeWithoutWindow = clearWindowPreservingZones(window, from: node)
    return insertIntoSubtreeAfterClearing(window, path: path, fullPath: path, treeWithoutWindow)
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

func removeWindowForRetile(_ window: WindowID, from node: Node) -> Node {
    guard occupiedWindows(in: node).contains(window) else { return node }
    let cleared = clearWindowPreservingZones(window, from: node)
    guard !occupiedWindows(in: cleared).isEmpty else { return .void }
    return compactVacatedBranches(cleared, preservingRoot: true)
}

private func compactVacatedBranches(_ node: Node, preservingRoot: Bool) -> Node {
    guard case .split(let split) = node else { return node }
    let cells = split.cells.map { cell in
        makeCell(
            weight: cell.weight,
            node: compactVacatedBranches(cell.node, preservingRoot: false)
        )
    }
    guard !preservingRoot else {
        return .split(makeSplit(axis: split.axis, cells: cells))
    }

    let occupied = cells.filter { !isUnoccupiedSubtree($0.node) }
    switch occupied.count {
    case 0:
        return .void
    case 1:
        return occupied[0].node
    default:
        return .split(makeSplit(axis: split.axis, cells: cells))
    }
}

private func insertIntoSubtreeAfterClearing(
    _ window: WindowID,
    path: NodePath,
    fullPath: NodePath,
    _ node: Node
) -> Result<Node, TreeSubtreeInsertError> {
    guard let nextIndex = path.first else {
        return .success(insertAtCenter(window, node))
    }
    guard case .split(let split) = node, split.cells.indices.contains(nextIndex) else {
        return .failure(.pathNotFound(fullPath))
    }

    switch insertIntoSubtreeAfterClearing(
        window,
        path: Array(path.dropFirst()),
        fullPath: fullPath,
        split.cells[nextIndex].node
    ) {
    case .success(let child):
        return .success(splitByReplacingCell(split, at: nextIndex, with: child))
    case .failure(let error):
        return .failure(error)
    }
}

private struct WindowPathStep {
    let parentPath: NodePath
    let split: Split
    let childIndex: Int
}

private struct ResizeTarget {
    let parentPath: NodePath
    let childIndex: Int
    let neighborIndex: Int
}

private func pathToWindow(_ window: WindowID, in node: Node, parentPath: NodePath) -> [WindowPathStep]? {
    switch node {
    case .void:
        return nil
    case .leaf(let id):
        return id == window ? [] : nil
    case .split(let split):
        for (index, cell) in split.cells.enumerated() {
            guard let childPath = pathToWindow(window, in: cell.node, parentPath: parentPath + [index]) else {
                continue
            }
            return [WindowPathStep(parentPath: parentPath, split: split, childIndex: index)] + childPath
        }
        return nil
    }
}

private func resizeTarget(in path: [WindowPathStep], direction: Direction) -> ResizeTarget? {
    for step in path.reversed() where step.split.axis == direction.layoutAxisForPush {
        guard let neighborIndex = direction.adjacentResizeIndex(from: step.childIndex, count: step.split.cells.count) else {
            continue
        }
        return ResizeTarget(
            parentPath: step.parentPath,
            childIndex: step.childIndex,
            neighborIndex: neighborIndex
        )
    }
    return nil
}

private func resizeSplit(
    at path: NodePath,
    childIndex: Int,
    neighborIndex: Int,
    delta: Double,
    in node: Node
) -> Result<Node, TreeResizeError> {
    guard let nextIndex = path.first else {
        guard case .split(let split) = node else {
            preconditionFailure("Resize target path did not end at a split")
        }
        return resizedSplitNode(split, childIndex: childIndex, neighborIndex: neighborIndex, delta: delta)
    }

    guard case .split(let split) = node, split.cells.indices.contains(nextIndex) else {
        preconditionFailure("Resize target path is invalid")
    }
    switch resizeSplit(
        at: Array(path.dropFirst()),
        childIndex: childIndex,
        neighborIndex: neighborIndex,
        delta: delta,
        in: split.cells[nextIndex].node
    ) {
    case .success(let child):
        return .success(splitByReplacingCell(split, at: nextIndex, with: child))
    case .failure(let error):
        return .failure(error)
    }
}

private func resizedSplitNode(
    _ split: Split,
    childIndex: Int,
    neighborIndex: Int,
    delta: Double
) -> Result<Node, TreeResizeError> {
    let child = split.cells[childIndex]
    let neighbor = split.cells[neighborIndex]
    let childWeight = child.weight + delta
    let neighborWeight = neighbor.weight - delta

    guard childWeight > 0, neighborWeight > 0 else {
        return .failure(.nonPositiveWeight)
    }

    let cells = split.cells
        .replacingCell(at: childIndex, with: makeCell(weight: childWeight, node: child.node))
        .replacingCell(at: neighborIndex, with: makeCell(weight: neighborWeight, node: neighbor.node))
    return .success(.split(makeSplit(axis: split.axis, cells: cells)))
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

private func insertAtRootCorner(_ window: WindowID, _ corner: Corner, _ node: Node) -> Node {
    switch node {
    case .split(let split) where split.axis == .horizontal:
        let targetIndex = corner.horizontalDirection.edgeInsertionIndex(count: split.cells.count)
        return splitByReplacingCell(
            split,
            at: targetIndex,
            with: insertIntoCornerSide(window, corner, split.cells[targetIndex].node)
        )
    case .void, .leaf, .split:
        let side = insertIntoCornerSide(window, corner, node)
        switch corner {
        case .topLeft, .bottomLeft:
            return .split(makeSplit(axis: .horizontal, cells: [
                makeCell(weight: 1, node: side),
                makeCell(weight: 1, node: .void)
            ]))
        case .topRight, .bottomRight:
            return .split(makeSplit(axis: .horizontal, cells: [
                makeCell(weight: 1, node: .void),
                makeCell(weight: 1, node: side)
            ]))
        }
    }
}

private func insertIntoCornerSide(_ window: WindowID, _ corner: Corner, _ node: Node) -> Node {
    let verticalDirection = corner.verticalDirection
    switch node {
    case .void:
        return edgeSplit(inserted: .leaf(window), existing: .void, direction: verticalDirection)
    case .leaf:
        return edgeSplit(inserted: .leaf(window), existing: node, direction: verticalDirection)
    case .split(let split) where split.axis == .vertical:
        let targetIndex = verticalDirection.edgeInsertionIndex(count: split.cells.count)
        return splitByReplacingCell(
            split,
            at: targetIndex,
            with: insertIntoLane(window, corner.horizontalDirection, split.cells[targetIndex].node, nextAxis: .horizontal)
        )
    case .split:
        return edgeSplit(inserted: .leaf(window), existing: node, direction: verticalDirection)
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
            if !containsEmptySlot(node) {
                return edgeSplit(inserted: .leaf(window), existing: node, direction: direction)
            }
            return insertIntoCenterLane(window, direction, split)
        }

        let targetIndex = direction.edgeInsertionIndex(count: split.cells.count)
        return splitByReplacingCell(
            split,
            at: targetIndex,
            with: insertIntoLane(window, direction, split.cells[targetIndex].node, nextAxis: direction.splitLineAxis)
        )
    }
}

private func containsEmptySlot(_ node: Node) -> Bool {
    switch node {
    case .void:
        return true
    case .leaf:
        return false
    case .split(let split):
        return split.cells.contains { containsEmptySlot($0.node) }
    }
}

private func insertIntoVerticalRowRealm(_ window: WindowID, _ direction: Direction, _ split: Split) -> Node {
    let targetIndex = direction.edgeInsertionIndex(count: split.cells.count)
    return splitByReplacingCell(split, at: targetIndex, with: insertIntoHorizontalRow(window, split.cells[targetIndex].node))
}

private func insertIntoHorizontalRow(_ window: WindowID, _ node: Node) -> Node {
    guard !isUnoccupiedSubtree(node) else {
        return .leaf(window)
    }

    switch node {
    case .void:
        return .leaf(window)
    case .leaf:
        return .split(makeSplit(axis: .horizontal, cells: [
            makeCell(weight: 1, node: node),
            makeCell(weight: 1, node: .leaf(window))
        ]))
    case .split(let split) where split.axis == .horizontal:
        let cells = split.cells.insertingCell(makeCell(weight: 1, node: .leaf(window)), at: max(0, split.cells.count - 1))
        return .split(makeSplit(axis: split.axis, cells: cells))
    case .split:
        return insertIntoLane(window, .right, node, nextAxis: .horizontal)
    }
}

private func insertIntoCenterLane(_ window: WindowID, _ direction: Direction, _ split: Split) -> Node {
    let centerLane = centeredLane(in: split.cells)
    let target = centerLane.cells[centerLane.index]
    let replacement = insertAtRootEdge(window, direction, target.node)
    let cells = centerLane.cells.replacingCell(at: centerLane.index, with: makeCell(weight: target.weight, node: replacement))
    return .split(makeSplit(axis: split.axis, cells: cells))
}

private func insertIntoLane(_ window: WindowID, _ direction: Direction, _ node: Node, nextAxis: Axis) -> Node {
    guard !isUnoccupiedSubtree(node) else {
        return .leaf(window)
    }

    switch node {
    case .void:
        return .leaf(window)
    case .leaf:
        return splitLaneLeaf(inserted: .leaf(window), existing: node, direction: direction, axis: nextAxis)
    case .split(let split):
        let targetIndex = direction.centerFacingIndex(axis: split.axis, count: split.cells.count)
        return splitByReplacingCell(
            split,
            at: targetIndex,
            with: insertIntoLane(window, direction, split.cells[targetIndex].node, nextAxis: split.axis.toggled)
        )
    }
}

private func isUnoccupiedSubtree(_ node: Node) -> Bool {
    switch node {
    case .void:
        return true
    case .leaf:
        return false
    case .split(let split):
        return split.cells.allSatisfy { isUnoccupiedSubtree($0.node) }
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

private struct CenterLane {
    let cells: [Cell]
    let index: Int
}

private func centeredLane(in cells: [Cell]) -> CenterLane {
    if cells.count == 2,
       let emptyIndex = cells.indices.first(where: { isUnoccupiedSubtree(cells[$0].node) }) {
        return CenterLane(cells: cells, index: emptyIndex)
    }
    if cells.count == 2 {
        return CenterLane(cells: cells.insertingCell(makeCell(weight: 1, node: .void), at: 1), index: 1)
    }
    return CenterLane(cells: cells, index: cells.count / 2)
}

private func splitByReplacingCell(_ split: Split, at index: Int, with node: Node) -> Node {
    let target = split.cells[index]
    return .split(makeSplit(
        axis: split.axis,
        cells: split.cells.replacingCell(at: index, with: makeCell(weight: target.weight, node: node))
    ))
}

private extension Array where Element == Cell {
    func replacingCell(at index: Int, with cell: Cell) -> [Cell] {
        enumerated().map { currentIndex, element in
            currentIndex == index ? cell : element
        }
    }

    func insertingCell(_ cell: Cell, at index: Int) -> [Cell] {
        let insertionIndex = Swift.max(0, Swift.min(index, count))
        return Array(prefix(insertionIndex)) + [cell] + Array(dropFirst(insertionIndex))
    }
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

    func adjacentResizeIndex(from index: Int, count: Int) -> Int? {
        switch self {
        case .left, .up:
            let neighbor = index - 1
            return neighbor >= 0 ? neighbor : nil
        case .right, .down:
            let neighbor = index + 1
            return neighbor < count ? neighbor : nil
        }
    }
}

private extension Corner {
    var horizontalDirection: Direction {
        switch self {
        case .topLeft, .bottomLeft:
            return .left
        case .topRight, .bottomRight:
            return .right
        }
    }

    var verticalDirection: Direction {
        switch self {
        case .topLeft, .topRight:
            return .up
        case .bottomLeft, .bottomRight:
            return .down
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
