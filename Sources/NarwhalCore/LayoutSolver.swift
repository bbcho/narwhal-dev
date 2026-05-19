import CoreGraphics

public struct WindowConstraints: Equatable, Codable, Sendable {
    public let minWidth: Double?
    public let minHeight: Double?

    public init(minWidth: Double? = nil, minHeight: Double? = nil) {
        self.minWidth = WindowConstraints.validMinimum(minWidth)
        self.minHeight = WindowConstraints.validMinimum(minHeight)
    }

    public var isEmpty: Bool {
        minWidth == nil && minHeight == nil
    }

    public func merged(with other: WindowConstraints) -> WindowConstraints {
        WindowConstraints(
            minWidth: maxOptional(minWidth, other.minWidth),
            minHeight: maxOptional(minHeight, other.minHeight)
        )
    }

    private static func validMinimum(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

public enum LayoutAdjustmentReason: Equatable, Sendable {
    case minimumWidth(Double)
    case minimumHeight(Double)
}

public struct LayoutAdjustment: Equatable, Sendable {
    public let windowID: WindowID
    public let requested: CGRect
    public let adjusted: CGRect
    public let reason: LayoutAdjustmentReason

    public init(windowID: WindowID, requested: CGRect, adjusted: CGRect, reason: LayoutAdjustmentReason) {
        self.windowID = windowID
        self.requested = requested
        self.adjusted = adjusted
        self.reason = reason
    }
}

public struct UnsatisfiableLayout: Error, Equatable, Sendable {
    public let displayID: DisplayID
    public let axis: Axis
    public let available: Double
    public let required: Double
    public let windows: [WindowID]

    public init(displayID: DisplayID, axis: Axis, available: Double, required: Double, windows: [WindowID]) {
        self.displayID = displayID
        self.axis = axis
        self.available = available
        self.required = required
        self.windows = windows
    }
}

public enum LayoutSolveStatus: Equatable, Sendable {
    case exact
    case adjusted([LayoutAdjustment])
}

public enum LayoutSolveResult: Equatable, Sendable {
    case solved(layout: Layout, status: LayoutSolveStatus)
    case unsatisfiable(UnsatisfiableLayout)
}

public func solveLayout(
    spaceState: SpaceState,
    displayID: DisplayID,
    frame: CGRect,
    gaps: Gaps,
    constraints: [WindowID: WindowConstraints]
) -> LayoutSolveResult {
    guard let displayState = spaceState.displays[displayID] else {
        return .solved(layout: Layout(tiled: [:], floatingZOrder: [], hidden: []), status: .exact)
    }

    let baseline = layout(spaceState: spaceState, displayID: displayID, frame: frame, gaps: gaps)
    let usableFrame = applyOuterGaps(gaps.outer, to: frame)
    switch solvedFrames(
        in: displayState.tree,
        frame: usableFrame,
        innerGap: gaps.inner,
        constraints: constraints,
        displayID: displayID
    ) {
    case .success(let tiled):
        let solved = Layout(tiled: tiled, floatingZOrder: displayState.floating, hidden: [])
        guard solved.tiled != baseline.tiled else {
            return .solved(layout: solved, status: .exact)
        }
        return .solved(
            layout: solved,
            status: .adjusted(adjustments(requested: baseline.tiled, adjusted: solved.tiled, constraints: constraints))
        )
    case .failure(let unsatisfiable):
        return .unsatisfiable(unsatisfiable)
    }
}

public func inferObservedConstraints(
    target: CGRect,
    actual: CGRect,
    tolerance: Double
) -> WindowConstraints? {
    let effectiveTolerance = max(0, tolerance)
    let minWidth = actual.width > target.width + effectiveTolerance ? Double(actual.width) : nil
    let minHeight = actual.height > target.height + effectiveTolerance ? Double(actual.height) : nil
    let constraints = WindowConstraints(minWidth: minWidth, minHeight: minHeight)
    return constraints.isEmpty ? nil : constraints
}

private struct MinimumSize {
    let width: Double
    let height: Double
    let windows: [WindowID]

    func length(on axis: Axis) -> Double {
        switch axis {
        case .horizontal:
            return width
        case .vertical:
            return height
        }
    }
}

private func solvedFrames(
    in node: Node,
    frame: CGRect,
    innerGap: Double,
    constraints: [WindowID: WindowConstraints],
    displayID: DisplayID
) -> Result<[WindowID: CGRect], UnsatisfiableLayout> {
    switch node {
    case .void:
        return .success([:])
    case .leaf(let id):
        let target = frame.insetBy(dx: innerGap / 2, dy: innerGap / 2).standardized
        if let unsatisfiable = unsatisfiableLeaf(
            id,
            target: target,
            constraints: constraints[id],
            displayID: displayID
        ) {
            return .failure(unsatisfiable)
        }
        return .success([id: target])
    case .split(let split):
        let minimums = split.cells.map { minimumSize(of: $0.node, innerGap: innerGap, constraints: constraints) }
        if let unsatisfiable = unsatisfiableSplit(
            displayID: displayID,
            frame: frame,
            axis: split.axis,
            minimums: minimums
        ) {
            return .failure(unsatisfiable)
        }

        guard let lengths = constrainedLengths(
            total: frame.length(on: split.axis),
            weights: split.cells.map(\.weight),
            minimums: minimums.map { $0.length(on: split.axis) }
        ) else {
            let required = minimums.map { $0.length(on: split.axis) }.reduce(0, +)
            return .failure(UnsatisfiableLayout(
                displayID: displayID,
                axis: split.axis,
                available: frame.length(on: split.axis),
                required: required,
                windows: minimums.flatMap(\.windows)
            ))
        }

        var tiled: [WindowID: CGRect] = [:]
        for (cell, childFrame) in zip(split.cells, splitFrames(frame, axis: split.axis, lengths: lengths)) {
            switch solvedFrames(
                in: cell.node,
                frame: childFrame,
                innerGap: innerGap,
                constraints: constraints,
                displayID: displayID
            ) {
            case .success(let childFrames):
                tiled.merge(childFrames) { _, next in next }
            case .failure(let unsatisfiable):
                return .failure(unsatisfiable)
            }
        }
        return .success(tiled)
    }
}

private func minimumSize(
    of node: Node,
    innerGap: Double,
    constraints: [WindowID: WindowConstraints]
) -> MinimumSize {
    switch node {
    case .void:
        return MinimumSize(width: 0, height: 0, windows: [])
    case .leaf(let id):
        let constraint = constraints[id] ?? WindowConstraints()
        return MinimumSize(
            width: constraint.minWidth.map { $0 + innerGap } ?? 0,
            height: constraint.minHeight.map { $0 + innerGap } ?? 0,
            windows: [id]
        )
    case .split(let split):
        let childMinimums = split.cells.map { minimumSize(of: $0.node, innerGap: innerGap, constraints: constraints) }
        switch split.axis {
        case .horizontal:
            return MinimumSize(
                width: childMinimums.map(\.width).reduce(0, +),
                height: childMinimums.map(\.height).max() ?? 0,
                windows: childMinimums.flatMap(\.windows)
            )
        case .vertical:
            return MinimumSize(
                width: childMinimums.map(\.width).max() ?? 0,
                height: childMinimums.map(\.height).reduce(0, +),
                windows: childMinimums.flatMap(\.windows)
            )
        }
    }
}

private func unsatisfiableSplit(
    displayID: DisplayID,
    frame: CGRect,
    axis: Axis,
    minimums: [MinimumSize]
) -> UnsatisfiableLayout? {
    let alongRequired = minimums.map { $0.length(on: axis) }.reduce(0, +)
    let alongAvailable = frame.length(on: axis)
    if alongRequired > alongAvailable + layoutTolerance {
        return UnsatisfiableLayout(
            displayID: displayID,
            axis: axis,
            available: alongAvailable,
            required: alongRequired,
            windows: minimums.flatMap(\.windows)
        )
    }

    let crossAxis = axis.toggled
    let crossRequired = minimums.map { $0.length(on: crossAxis) }.max() ?? 0
    let crossAvailable = frame.length(on: crossAxis)
    if crossRequired > crossAvailable + layoutTolerance {
        return UnsatisfiableLayout(
            displayID: displayID,
            axis: crossAxis,
            available: crossAvailable,
            required: crossRequired,
            windows: minimums.flatMap(\.windows)
        )
    }

    return nil
}

private func unsatisfiableLeaf(
    _ id: WindowID,
    target: CGRect,
    constraints: WindowConstraints?,
    displayID: DisplayID
) -> UnsatisfiableLayout? {
    guard let constraints else { return nil }
    if let minWidth = constraints.minWidth, Double(target.width) + layoutTolerance < minWidth {
        return UnsatisfiableLayout(
            displayID: displayID,
            axis: .horizontal,
            available: Double(target.width),
            required: minWidth,
            windows: [id]
        )
    }
    if let minHeight = constraints.minHeight, Double(target.height) + layoutTolerance < minHeight {
        return UnsatisfiableLayout(
            displayID: displayID,
            axis: .vertical,
            available: Double(target.height),
            required: minHeight,
            windows: [id]
        )
    }
    return nil
}

private func constrainedLengths(total: Double, weights: [Double], minimums: [Double]) -> [Double]? {
    guard weights.count == minimums.count, total.isFinite, total >= 0 else { return nil }
    guard minimums.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
    guard minimums.reduce(0, +) <= total + layoutTolerance else { return nil }

    var result = Array(repeating: 0.0, count: weights.count)
    var remaining = Set(weights.indices)
    var remainingTotal = total

    while !remaining.isEmpty {
        let remainingWeight = remaining.reduce(0.0) { $0 + weights[$1] }
        guard remainingWeight > 0 else { return nil }

        let binding = remaining.filter { index in
            let proposed = remainingTotal * weights[index] / remainingWeight
            return proposed + layoutTolerance < minimums[index]
        }

        guard !binding.isEmpty else {
            let ordered = remaining.sorted()
            var used = 0.0
            for (offset, index) in ordered.enumerated() {
                let value = offset == ordered.count - 1
                    ? remainingTotal - used
                    : remainingTotal * weights[index] / remainingWeight
                result[index] = max(0, value)
                used += result[index]
            }
            return result
        }

        for index in binding {
            result[index] = minimums[index]
            remainingTotal -= minimums[index]
            remaining.remove(index)
        }
    }

    return result
}

private func splitFrames(_ frame: CGRect, axis: Axis, lengths: [Double]) -> [CGRect] {
    var offset = 0.0
    return lengths.enumerated().map { index, length in
        let isLast = index == lengths.count - 1
        switch axis {
        case .horizontal:
            let width = isLast ? Double(frame.width) - offset : length
            defer { offset += width }
            return CGRect(x: frame.minX + offset, y: frame.minY, width: width, height: frame.height)
        case .vertical:
            let height = isLast ? Double(frame.height) - offset : length
            defer { offset += height }
            return CGRect(x: frame.minX, y: frame.minY + offset, width: frame.width, height: height)
        }
    }
}

private func adjustments(
    requested: [WindowID: CGRect],
    adjusted: [WindowID: CGRect],
    constraints: [WindowID: WindowConstraints]
) -> [LayoutAdjustment] {
    adjusted.keys.sorted(by: { $0.raw < $1.raw }).compactMap { id in
        guard let requestedFrame = requested[id],
              let adjustedFrame = adjusted[id],
              requestedFrame != adjustedFrame,
              let constraint = constraints[id]
        else {
            return nil
        }
        if let minWidth = constraint.minWidth, adjustedFrame.width != requestedFrame.width {
            return LayoutAdjustment(
                windowID: id,
                requested: requestedFrame,
                adjusted: adjustedFrame,
                reason: .minimumWidth(minWidth)
            )
        }
        if let minHeight = constraint.minHeight, adjustedFrame.height != requestedFrame.height {
            return LayoutAdjustment(
                windowID: id,
                requested: requestedFrame,
                adjusted: adjustedFrame,
                reason: .minimumHeight(minHeight)
            )
        }
        return nil
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

private func maxOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)):
        return max(lhs, rhs)
    case (.some(let lhs), .none):
        return lhs
    case (.none, .some(let rhs)):
        return rhs
    case (.none, .none):
        return nil
    }
}

private let layoutTolerance = 0.0001

private extension CGRect {
    func length(on axis: Axis) -> Double {
        switch axis {
        case .horizontal:
            return Double(width)
        case .vertical:
            return Double(height)
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
