import CoreGraphics

public enum VisiblePartitionResizeError: Error, Equatable, Sendable {
    case windowNotFound(WindowID)
    case ambiguousChangedEdges
    case noVisibleNeighbor(Direction)
    case invalidPartition
    case nonGuillotinePartition
    case reconstructionMismatch
}

public func resizeVisibleSeamInTree(
    _ windowID: WindowID,
    from oldFrame: CGRect,
    to newFrame: CGRect,
    rootFrame: CGRect,
    innerGap: Double,
    constraints: [WindowID: WindowConstraints] = [:],
    _ tree: Node
) -> Result<Node, VisiblePartitionResizeError> {
    guard oldFrame.narwhalIsFinitePositive,
          newFrame.narwhalIsFinitePositive,
          rootFrame.narwhalIsFinitePositive,
          innerGap.isFinite,
          innerGap >= 0
    else {
        return .failure(.invalidPartition)
    }
    let geometry = SeamGeometry(rootFrame: rootFrame, innerGap: innerGap, constraints: constraints)

    let changes = changedEdges(from: oldFrame, to: newFrame)
    switch changes.count {
    case 0:
        return occupiedSlotIndex(of: windowID, in: renderPartition(tree, geometry)).map { _ in tree }
    case 1:
        return resizeSingleSeam(windowID, change: changes[0], to: newFrame, geometry, tree)
    case 2 where changes[0].direction.layoutAxisForPush != changes[1].direction.layoutAxisForPush:
        // A corner drag is two independent seam moves, one per axis.
        return resizeSingleSeam(windowID, change: changes[0], to: newFrame, geometry, tree)
            .flatMap { resizeSingleSeam(windowID, change: changes[1], to: newFrame, geometry, $0) }
    default:
        return .failure(.ambiguousChangedEdges)
    }
}

private struct SeamGeometry {
    let rootFrame: CGRect
    let innerGap: Double
    let constraints: [WindowID: WindowConstraints]

    var gapInset: CGFloat { CGFloat(innerGap) / 2 }
}

private func occupiedSlotIndex(
    of windowID: WindowID,
    in rendered: RenderedPartition
) -> Result<Int, VisiblePartitionResizeError> {
    let sources = rendered.slots.indices.filter {
        rendered.slots[$0].occupancy == .occupied(windowID)
    }
    guard sources.count == 1, let sourceIndex = sources.first else {
        return sources.isEmpty ? .failure(.windowNotFound(windowID)) : .failure(.invalidPartition)
    }
    return .success(sourceIndex)
}

private func resizeSingleSeam(
    _ windowID: WindowID,
    change: EdgeChange,
    to newFrame: CGRect,
    _ geometry: SeamGeometry,
    _ tree: Node
) -> Result<Node, VisiblePartitionResizeError> {
    let rendered = renderPartition(tree, geometry)
    let sourceIndex: Int
    switch occupiedSlotIndex(of: windowID, in: rendered) {
    case .success(let index):
        sourceIndex = index
    case .failure(let error):
        return .failure(error)
    }

    let gapInset = geometry.gapInset
    let rootFrame = geometry.rootFrame
    let newBoundary = quantizedSplitBoundary(
        partitionBoundary(for: change, frame: newFrame, gapInset: gapInset)
    )
    var adjusted = rendered.slots
    let seam = seamSides(of: sourceIndex, in: adjusted, direction: change.direction)
    guard !seam.opposite.isEmpty else {
        return .failure(.noVisibleNeighbor(change.direction))
    }
    let oppositeFrames = seam.opposite.map { adjusted[$0].frame }
    guard seam.moving.allSatisfy({ index in
        let movingFrame = adjusted[index].frame
        return neighborsCoverSourceEdge(
            oppositeFrames.filter { sharesSeam($0, movingFrame, change.direction) },
            source: movingFrame,
            direction: change.direction
        )
    }) else {
        return .failure(.invalidPartition)
    }

    for index in seam.moving {
        adjusted[index].frame = frameByMovingBoundary(
            of: adjusted[index].frame,
            direction: change.direction,
            to: newBoundary
        )
    }
    for index in seam.opposite {
        adjusted[index].frame = frameByMovingOppositeBoundary(
            of: adjusted[index].frame,
            direction: change.direction,
            to: newBoundary
        )
    }
    let normalizedSourceFrame = adjusted[sourceIndex].frame
        .insetBy(dx: gapInset, dy: gapInset)
        .standardized

    guard isValidPartition(adjusted, covering: rootFrame) else {
        return .failure(.invalidPartition)
    }

    let rebuilt: Node
    switch rebuildPartition(
        adjusted,
        in: rootFrame,
        movedBoundary: PartitionBoundary(axis: change.direction.layoutAxisForPush, coordinate: newBoundary),
        originalRegions: rendered.splitRegions
    ) {
    case .success(let node):
        rebuilt = node
    case .failure(let error):
        return .failure(error)
    }

    let rebuiltSlots = renderPartition(rebuilt, geometry).slots
    guard partitionsMatch(adjusted, rebuiltSlots),
          let rebuiltSource = rebuiltSlots.first(where: { $0.occupancy == .occupied(windowID) }),
          rebuiltSource.frame.insetBy(dx: gapInset, dy: gapInset).standardized
            .narwhalApproximatelyEquals(normalizedSourceFrame, tolerance: configuredGapTolerance)
    else {
        return .failure(.reconstructionMismatch)
    }
    return .success(rebuilt)
}

private struct PartitionSlot {
    let occupancy: SlotOccupancy
    var frame: CGRect
}

private struct PartitionBoundary {
    let axis: Axis
    let coordinate: CGFloat
}

private struct OriginalSplitRegion {
    let frame: CGRect
    let axis: Axis
    let boundaries: [CGFloat]
}

private struct RenderedPartition {
    let slots: [PartitionSlot]
    let splitRegions: [OriginalSplitRegion]
}

private struct EdgeChange {
    let direction: Direction
}

private func renderPartition(_ node: Node, _ geometry: SeamGeometry) -> RenderedPartition {
    renderPartition(node, in: geometry.rootFrame, geometry)
}

private func renderPartition(_ node: Node, in frame: CGRect, _ geometry: SeamGeometry) -> RenderedPartition {
    switch node {
    case .void:
        return RenderedPartition(
            slots: [PartitionSlot(occupancy: .empty, frame: frame)],
            splitRegions: []
        )
    case .leaf(let windowID):
        return RenderedPartition(
            slots: [PartitionSlot(occupancy: .occupied(windowID), frame: frame)],
            splitRegions: []
        )
    case .split(let split):
        let childFrames = constrainedSplitFrames(
            split,
            in: frame,
            innerGap: geometry.innerGap,
            constraints: geometry.constraints
        )
        let children = zip(split.cells, childFrames).map { cell, childFrame in
            renderPartition(cell.node, in: childFrame, geometry)
        }
        let boundaries = Array(childFrames.dropLast()).map {
            split.axis == .horizontal ? $0.maxX : $0.maxY
        }
        return RenderedPartition(
            slots: children.flatMap(\.slots),
            splitRegions: [OriginalSplitRegion(frame: frame, axis: split.axis, boundaries: boundaries)]
                + children.flatMap(\.splitRegions)
        )
    }
}

private func changedEdges(from oldFrame: CGRect, to newFrame: CGRect) -> [EdgeChange] {
    let edges = [
        (Direction.left, oldFrame.minX, newFrame.minX),
        (.right, oldFrame.maxX, newFrame.maxX),
        (.up, oldFrame.minY, newFrame.minY),
        (.down, oldFrame.maxY, newFrame.maxY)
    ]
    // A single deliberate edge drag can also produce small app-size rounding.
    let significantEdges = edges.filter { abs($0.1 - $0.2) > frameWriteSettleTolerance }
    let tolerance = significantEdges.count == 1
        ? frameWriteSettleTolerance
        : GeometryTolerances.externalResizeDirection
    return edges.compactMap { direction, oldValue, newValue in
        abs(oldValue - newValue) > tolerance ? EdgeChange(direction: direction) : nil
    }
}

private func partitionBoundary(for change: EdgeChange, frame: CGRect, gapInset: CGFloat) -> CGFloat {
    switch change.direction {
    case .left:
        return frame.minX - gapInset
    case .right:
        return frame.maxX + gapInset
    case .up:
        return frame.minY - gapInset
    case .down:
        return frame.maxY + gapInset
    }
}

private struct SeamSides {
    let moving: [Int]
    let opposite: [Int]
}

/// Collects every slot on both sides of the source's dragged edge that shares
/// one continuous seam with it. Moving only the source's direct neighbors
/// would leave a slot that also borders those neighbors behind, breaking the
/// partition (a short window beside a tall one).
private func seamSides(of sourceIndex: Int, in slots: [PartitionSlot], direction: Direction) -> SeamSides {
    let coordinate = edgeCoordinate(of: slots[sourceIndex].frame, direction)
    var moving: Set<Int> = [sourceIndex]
    var opposite: Set<Int> = []
    var grew = true
    while grew {
        grew = false
        for index in slots.indices where !moving.contains(index) && !opposite.contains(index) {
            let frame = slots[index].frame
            if approximatelyEqual(edgeCoordinate(of: frame, direction), coordinate),
               opposite.contains(where: { sharesSeam(frame, slots[$0].frame, direction) }) {
                moving.insert(index)
                grew = true
            } else if approximatelyEqual(edgeCoordinate(of: frame, direction.opposite), coordinate),
                      moving.contains(where: { sharesSeam(frame, slots[$0].frame, direction) }) {
                opposite.insert(index)
                grew = true
            }
        }
    }
    return SeamSides(moving: moving.sorted(), opposite: opposite.sorted())
}

private extension Direction {
    var opposite: Direction {
        switch self {
        case .left:
            return .right
        case .right:
            return .left
        case .up:
            return .down
        case .down:
            return .up
        }
    }
}

private func edgeCoordinate(of frame: CGRect, _ direction: Direction) -> CGFloat {
    switch direction {
    case .left:
        return frame.minX
    case .right:
        return frame.maxX
    case .up:
        return frame.minY
    case .down:
        return frame.maxY
    }
}

private func sharesSeam(_ first: CGRect, _ second: CGRect, _ direction: Direction) -> Bool {
    switch direction {
    case .left, .right:
        return overlap(first.minY, first.maxY, second.minY, second.maxY) > configuredGapTolerance
    case .up, .down:
        return overlap(first.minX, first.maxX, second.minX, second.maxX) > configuredGapTolerance
    }
}

private func neighborsCoverSourceEdge(
    _ neighbors: [CGRect],
    source: CGRect,
    direction: Direction
) -> Bool {
    let sourceInterval: ClosedRange<CGFloat>
    let intervals: [ClosedRange<CGFloat>]
    switch direction {
    case .left, .right:
        sourceInterval = source.minY...source.maxY
        intervals = neighbors.map { max(source.minY, $0.minY)...min(source.maxY, $0.maxY) }
    case .up, .down:
        sourceInterval = source.minX...source.maxX
        intervals = neighbors.map { max(source.minX, $0.minX)...min(source.maxX, $0.maxX) }
    }
    let ordered = intervals.sorted { lhs, rhs in
        lhs.lowerBound == rhs.lowerBound
            ? lhs.upperBound < rhs.upperBound
            : lhs.lowerBound < rhs.lowerBound
    }
    var coveredThrough = sourceInterval.lowerBound
    for interval in ordered {
        guard interval.lowerBound <= coveredThrough + configuredGapTolerance else { return false }
        coveredThrough = max(coveredThrough, interval.upperBound)
    }
    return coveredThrough >= sourceInterval.upperBound - configuredGapTolerance
}

private func frameByMovingBoundary(
    of frame: CGRect,
    direction: Direction,
    to boundary: CGFloat
) -> CGRect {
    switch direction {
    case .left:
        return CGRect(x: boundary, y: frame.minY, width: frame.maxX - boundary, height: frame.height)
    case .right:
        return CGRect(x: frame.minX, y: frame.minY, width: boundary - frame.minX, height: frame.height)
    case .up:
        return CGRect(x: frame.minX, y: boundary, width: frame.width, height: frame.maxY - boundary)
    case .down:
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: boundary - frame.minY)
    }
}

private func frameByMovingOppositeBoundary(
    of frame: CGRect,
    direction: Direction,
    to boundary: CGFloat
) -> CGRect {
    switch direction {
    case .left:
        return CGRect(x: frame.minX, y: frame.minY, width: boundary - frame.minX, height: frame.height)
    case .right:
        return CGRect(x: boundary, y: frame.minY, width: frame.maxX - boundary, height: frame.height)
    case .up:
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: boundary - frame.minY)
    case .down:
        return CGRect(x: frame.minX, y: boundary, width: frame.width, height: frame.maxY - boundary)
    }
}

private func isValidPartition(_ slots: [PartitionSlot], covering rootFrame: CGRect) -> Bool {
    guard slots.allSatisfy({ slot in
        slot.frame.narwhalIsFinitePositive
            && slot.frame.minX >= rootFrame.minX - configuredGapTolerance
            && slot.frame.minY >= rootFrame.minY - configuredGapTolerance
            && slot.frame.maxX <= rootFrame.maxX + configuredGapTolerance
            && slot.frame.maxY <= rootFrame.maxY + configuredGapTolerance
    }) else {
        return false
    }

    for firstIndex in slots.indices {
        for secondIndex in slots.indices where secondIndex > firstIndex {
            let intersection = slots[firstIndex].frame.intersection(slots[secondIndex].frame)
            if !intersection.isNull,
               intersection.width > configuredGapTolerance,
               intersection.height > configuredGapTolerance {
                return false
            }
        }
    }

    let coveredArea = slots.map { $0.frame.narwhalArea }.reduce(0, +)
    let areaTolerance = configuredGapTolerance * max(rootFrame.width, rootFrame.height)
    return abs(coveredArea - rootFrame.narwhalArea) <= areaTolerance
}

private func rebuildPartition(
    _ slots: [PartitionSlot],
    in region: CGRect,
    movedBoundary: PartitionBoundary,
    originalRegions: [OriginalSplitRegion]
) -> Result<Node, VisiblePartitionResizeError> {
    if slots.count == 1, let slot = slots.first {
        guard slot.frame.narwhalApproximatelyEquals(region, tolerance: configuredGapTolerance) else {
            return .failure(.nonGuillotinePartition)
        }
        switch slot.occupancy {
        case .empty:
            return .success(.void)
        case .occupied(let windowID):
            return .success(.leaf(windowID))
        }
    }

    let horizontalCuts = validCuts(axis: .horizontal, slots: slots, in: region)
    let verticalCuts = validCuts(axis: .vertical, slots: slots, in: region)
    guard !horizontalCuts.isEmpty || !verticalCuts.isEmpty else {
        return .failure(.nonGuillotinePartition)
    }

    let axis = preferredAxis(
        horizontalCuts: horizontalCuts,
        verticalCuts: verticalCuts,
        region: region,
        movedBoundary: movedBoundary,
        originalRegions: originalRegions
    )
    let cuts = axis == .horizontal ? horizontalCuts : verticalCuts
    let lower = axis == .horizontal ? region.minX : region.minY
    let upper = axis == .horizontal ? region.maxX : region.maxY
    let boundaries = [lower] + cuts + [upper]
    var cells: [Cell] = []
    for index in 0..<(boundaries.count - 1) {
        let band = bandFrame(
            in: region,
            axis: axis,
            lower: boundaries[index],
            upper: boundaries[index + 1]
        )
        let bandSlots = slots.filter {
            let center = axis == .horizontal ? $0.frame.midX : $0.frame.midY
            return center >= boundaries[index] - configuredGapTolerance
                && center <= boundaries[index + 1] + configuredGapTolerance
        }
        guard !bandSlots.isEmpty else { return .failure(.nonGuillotinePartition) }
        let child: Node
        switch rebuildPartition(
            bandSlots,
            in: band,
            movedBoundary: movedBoundary,
            originalRegions: originalRegions
        ) {
        case .success(let node):
            child = node
        case .failure(let error):
            return .failure(error)
        }
        let regionExtent = axis == .horizontal ? region.width : region.height
        let bandExtent = axis == .horizontal ? band.width : band.height
        let weight = Double(bandExtent / regionExtent) * Double(boundaries.count - 1)
        guard case .success(let cell) = Cell.create(weight: weight, node: child) else {
            return .failure(.invalidPartition)
        }
        cells.append(cell)
    }
    guard case .success(let split) = Split.create(axis: axis, cells: cells) else {
        return .failure(.invalidPartition)
    }
    return .success(.split(split))
}

private func validCuts(axis: Axis, slots: [PartitionSlot], in region: CGRect) -> [CGFloat] {
    let lower = axis == .horizontal ? region.minX : region.minY
    let upper = axis == .horizontal ? region.maxX : region.maxY
    let coordinates = slots.flatMap { slot -> [CGFloat] in
        axis == .horizontal
            ? [slot.frame.minX, slot.frame.maxX]
            : [slot.frame.minY, slot.frame.maxY]
    }
    return uniqueSorted(coordinates.filter {
        $0 > lower + configuredGapTolerance && $0 < upper - configuredGapTolerance
    }).filter { coordinate in
        var hasLeading = false
        var hasTrailing = false
        for slot in slots {
            let slotLower = axis == .horizontal ? slot.frame.minX : slot.frame.minY
            let slotUpper = axis == .horizontal ? slot.frame.maxX : slot.frame.maxY
            if slotUpper <= coordinate + configuredGapTolerance {
                hasLeading = true
            } else if slotLower >= coordinate - configuredGapTolerance {
                hasTrailing = true
            } else {
                return false
            }
        }
        return hasLeading && hasTrailing
    }
}

private func preferredAxis(
    horizontalCuts: [CGFloat],
    verticalCuts: [CGFloat],
    region: CGRect,
    movedBoundary: PartitionBoundary,
    originalRegions: [OriginalSplitRegion]
) -> Axis {
    if movedBoundary.axis == .horizontal,
       horizontalCuts.contains(where: { approximatelyEqual($0, movedBoundary.coordinate) }) {
        return .horizontal
    }
    if movedBoundary.axis == .vertical,
       verticalCuts.contains(where: { approximatelyEqual($0, movedBoundary.coordinate) }) {
        return .vertical
    }
    if let original = originalRegions.first(where: {
        $0.frame.narwhalApproximatelyEquals(region, tolerance: configuredGapTolerance)
            && (($0.axis == .horizontal && !horizontalCuts.isEmpty)
                || ($0.axis == .vertical && !verticalCuts.isEmpty))
    }) {
        return original.axis
    }
    let originalBoundaries = originalRegions.flatMap { original in
        original.boundaries.map { PartitionBoundary(axis: original.axis, coordinate: $0) }
    }
    if horizontalCuts.contains(where: { cut in
        originalBoundaries.contains { $0.axis == .horizontal && approximatelyEqual($0.coordinate, cut) }
    }) {
        return .horizontal
    }
    if verticalCuts.contains(where: { cut in
        originalBoundaries.contains { $0.axis == .vertical && approximatelyEqual($0.coordinate, cut) }
    }) {
        return .vertical
    }
    return horizontalCuts.isEmpty ? .vertical : .horizontal
}

private func bandFrame(in region: CGRect, axis: Axis, lower: CGFloat, upper: CGFloat) -> CGRect {
    switch axis {
    case .horizontal:
        return CGRect(x: lower, y: region.minY, width: upper - lower, height: region.height)
    case .vertical:
        return CGRect(x: region.minX, y: lower, width: region.width, height: upper - lower)
    }
}

private func partitionsMatch(_ expected: [PartitionSlot], _ actual: [PartitionSlot]) -> Bool {
    let expectedOccupied = expected.compactMap { slot -> (WindowID, CGRect)? in
        guard case .occupied(let windowID) = slot.occupancy else { return nil }
        return (windowID, slot.frame)
    }
    let actualOccupied = actual.compactMap { slot -> (WindowID, CGRect)? in
        guard case .occupied(let windowID) = slot.occupancy else { return nil }
        return (windowID, slot.frame)
    }
    guard expectedOccupied.count == actualOccupied.count else { return false }
    for expectedSlot in expectedOccupied {
        guard let actualFrame = actualOccupied.first(where: { $0.0 == expectedSlot.0 })?.1,
              actualFrame.narwhalApproximatelyEquals(
                  expectedSlot.1,
                  tolerance: configuredGapTolerance
              )
        else {
            return false
        }
    }

    let expectedEmpty = sortedFrames(expected.filter { $0.occupancy == .empty }.map(\.frame))
    let actualEmpty = sortedFrames(actual.filter { $0.occupancy == .empty }.map(\.frame))
    return expectedEmpty.count == actualEmpty.count
        && zip(expectedEmpty, actualEmpty).allSatisfy {
            $0.narwhalApproximatelyEquals($1, tolerance: configuredGapTolerance)
        }
}

private func sortedFrames(_ frames: [CGRect]) -> [CGRect] {
    frames.sorted { lhs, rhs in
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        if lhs.height != rhs.height { return lhs.height < rhs.height }
        return lhs.width < rhs.width
    }
}

private func uniqueSorted(_ values: [CGFloat]) -> [CGFloat] {
    values.sorted().reduce(into: []) { result, value in
        if result.last.map({ !approximatelyEqual($0, value) }) ?? true {
            result.append(value)
        }
    }
}

private func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
    abs(lhs - rhs) <= configuredGapTolerance
}
