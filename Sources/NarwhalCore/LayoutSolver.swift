import CoreGraphics

public enum WindowConstraintAnchor: String, Equatable, Codable, Sendable {
    case min
    case center
    case max
}

public struct WindowConstraints: Equatable, Codable, Sendable {
    public let minWidth: Double?
    public let minHeight: Double?
    public let maxWidth: Double?
    public let maxHeight: Double?
    public let widthAnchor: WindowConstraintAnchor?
    public let heightAnchor: WindowConstraintAnchor?

    public init(
        minWidth: Double? = nil,
        minHeight: Double? = nil,
        maxWidth: Double? = nil,
        maxHeight: Double? = nil,
        widthAnchor: WindowConstraintAnchor? = nil,
        heightAnchor: WindowConstraintAnchor? = nil
    ) {
        let validMinWidth = WindowConstraints.validLength(minWidth)
        let validMinHeight = WindowConstraints.validLength(minHeight)
        let validMaxWidth = WindowConstraints.validMaximum(maxWidth, minimum: validMinWidth)
        let validMaxHeight = WindowConstraints.validMaximum(maxHeight, minimum: validMinHeight)
        self.minWidth = validMinWidth
        self.minHeight = validMinHeight
        self.maxWidth = validMaxWidth
        self.maxHeight = validMaxHeight
        self.widthAnchor = validMaxWidth == nil ? nil : widthAnchor ?? .center
        self.heightAnchor = validMaxHeight == nil ? nil : heightAnchor ?? .center
    }

    public var isEmpty: Bool {
        minWidth == nil && minHeight == nil && maxWidth == nil && maxHeight == nil
    }

    public func merged(with other: WindowConstraints) -> WindowConstraints {
        let widthMaximum = stricterMaximum(
            lhs: (maxWidth, widthAnchor),
            rhs: (other.maxWidth, other.widthAnchor)
        )
        let heightMaximum = stricterMaximum(
            lhs: (maxHeight, heightAnchor),
            rhs: (other.maxHeight, other.heightAnchor)
        )
        return WindowConstraints(
            minWidth: maxOptional(minWidth, other.minWidth),
            minHeight: maxOptional(minHeight, other.minHeight),
            maxWidth: widthMaximum.value,
            maxHeight: heightMaximum.value,
            widthAnchor: widthMaximum.anchor,
            heightAnchor: heightMaximum.anchor
        )
    }

    private static func validLength(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func validMaximum(_ value: Double?, minimum: Double?) -> Double? {
        guard let value = validLength(value) else { return nil }
        guard minimum.map({ value >= $0 }) ?? true else { return nil }
        return value
    }
}

public enum LayoutAdjustmentReason: Equatable, Sendable {
    case minimumWidth(Double)
    case minimumHeight(Double)
    case maximumWidth(Double)
    case maximumHeight(Double)
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
    guard target.narwhalIsFinitePositive, actual.narwhalIsFinitePositive else { return nil }
    let effectiveTolerance = max(0, tolerance)
    let minWidth = actual.width > target.width + effectiveTolerance ? Double(actual.width) : nil
    let minHeight = actual.height > target.height + effectiveTolerance ? Double(actual.height) : nil
    let widthMaximum = inferredMaximum(
        targetMin: target.minX,
        targetMax: target.maxX,
        targetLength: target.width,
        actualMin: actual.minX,
        actualMax: actual.maxX,
        actualLength: actual.width,
        tolerance: effectiveTolerance
    )
    let heightMaximum = inferredMaximum(
        targetMin: target.minY,
        targetMax: target.maxY,
        targetLength: target.height,
        actualMin: actual.minY,
        actualMax: actual.maxY,
        actualLength: actual.height,
        tolerance: effectiveTolerance
    )
    let constraints = WindowConstraints(
        minWidth: minWidth,
        minHeight: minHeight,
        maxWidth: widthMaximum?.value,
        maxHeight: heightMaximum?.value,
        widthAnchor: widthMaximum?.anchor,
        heightAnchor: heightMaximum?.anchor
    )
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
        return .success([id: applyingMaximums(constraints[id], to: target)])
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

        return zip(split.cells, splitFrames(frame, axis: split.axis, lengths: lengths)).reduce(
            Result<[WindowID: CGRect], UnsatisfiableLayout>.success([:])
        ) { result, entry in
            result.flatMap { tiled in
                solvedFrames(
                    in: entry.0.node,
                    frame: entry.1,
                    innerGap: innerGap,
                    constraints: constraints,
                    displayID: displayID
                ).map { childFrames in
                    tiled.merging(childFrames) { _, next in next }
                }
            }
        }
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

private func applyingMaximums(_ constraints: WindowConstraints?, to frame: CGRect) -> CGRect {
    guard let constraints else { return frame }
    let width = min(frame.width, constraints.maxWidth.map { CGFloat($0) } ?? frame.width)
    let height = min(frame.height, constraints.maxHeight.map { CGFloat($0) } ?? frame.height)
    return CGRect(
        x: anchoredOrigin(
            minimum: frame.minX,
            maximum: frame.maxX,
            length: width,
            anchor: constraints.widthAnchor
        ),
        y: anchoredOrigin(
            minimum: frame.minY,
            maximum: frame.maxY,
            length: height,
            anchor: constraints.heightAnchor
        ),
        width: width,
        height: height
    ).standardized
}

private func anchoredOrigin(
    minimum: CGFloat,
    maximum: CGFloat,
    length: CGFloat,
    anchor: WindowConstraintAnchor?
) -> CGFloat {
    switch anchor ?? .center {
    case .min:
        return minimum
    case .center:
        return minimum + (maximum - minimum - length) / 2
    case .max:
        return maximum - length
    }
}

private struct LengthAllocationState {
    let result: [Double]
    let remaining: Set<Int>
    let remainingTotal: Double
}

private func constrainedLengths(total: Double, weights: [Double], minimums: [Double]) -> [Double]? {
    guard weights.count == minimums.count, total.isFinite, total >= 0 else { return nil }
    guard minimums.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
    guard minimums.reduce(0, +) <= total + layoutTolerance else { return nil }

    return allocateConstrainedLengths(
        LengthAllocationState(
            result: Array(repeating: 0.0, count: weights.count),
            remaining: Set(weights.indices),
            remainingTotal: total
        ),
        weights: weights,
        minimums: minimums
    )
}

private func allocateConstrainedLengths(
    _ state: LengthAllocationState,
    weights: [Double],
    minimums: [Double]
) -> [Double]? {
    guard !state.remaining.isEmpty else { return state.result }

    let remainingWeight = state.remaining.reduce(0.0) { $0 + weights[$1] }
    guard remainingWeight > 0 else { return nil }

    let binding = state.remaining.filter { index in
        let proposed = state.remainingTotal * weights[index] / remainingWeight
        return proposed + layoutTolerance < minimums[index]
    }

    guard !binding.isEmpty else {
        return fillRemainingLengths(state, weights: weights, remainingWeight: remainingWeight)
    }

    let bound = binding.reduce(state) { state, index in
        LengthAllocationState(
            result: state.result.setting(index, to: minimums[index]),
            remaining: state.remaining.subtracting([index]),
            remainingTotal: state.remainingTotal - minimums[index]
        )
    }
    return allocateConstrainedLengths(bound, weights: weights, minimums: minimums)
}

private struct FilledLengthAccumulator {
    let result: [Double]
    let used: Double
}

private func fillRemainingLengths(
    _ state: LengthAllocationState,
    weights: [Double],
    remainingWeight: Double
) -> [Double] {
    let ordered = state.remaining.sorted()
    return ordered.enumerated().reduce(FilledLengthAccumulator(result: state.result, used: 0.0)) { filled, entry in
        let (offset, index) = entry
        let value = offset == ordered.count - 1
            ? state.remainingTotal - filled.used
            : state.remainingTotal * weights[index] / remainingWeight
        let allocated = max(0, value)
        return FilledLengthAccumulator(
            result: filled.result.setting(index, to: allocated),
            used: filled.used + allocated
        )
    }.result
}

private extension Array {
    func setting(_ index: Index, to value: Element) -> [Element] {
        enumerated().map { currentIndex, element in
            currentIndex == index ? value : element
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
        if let maxWidth = constraint.maxWidth, adjustedFrame.width != requestedFrame.width {
            return LayoutAdjustment(
                windowID: id,
                requested: requestedFrame,
                adjusted: adjustedFrame,
                reason: .maximumWidth(maxWidth)
            )
        }
        if let maxHeight = constraint.maxHeight, adjustedFrame.height != requestedFrame.height {
            return LayoutAdjustment(
                windowID: id,
                requested: requestedFrame,
                adjusted: adjustedFrame,
                reason: .maximumHeight(maxHeight)
            )
        }
        return nil
    }
}

private struct MaximumConstraint {
    let value: Double
    let anchor: WindowConstraintAnchor
}

private func inferredMaximum(
    targetMin: CGFloat,
    targetMax: CGFloat,
    targetLength: CGFloat,
    actualMin: CGFloat,
    actualMax: CGFloat,
    actualLength: CGFloat,
    tolerance: Double
) -> MaximumConstraint? {
    guard Double(actualLength) + tolerance < Double(targetLength) else { return nil }
    let edgeTolerance = max(CGFloat(tolerance), 16)
    let candidates: [(WindowConstraintAnchor, CGFloat)] = [
        (.min, abs(actualMin - targetMin)),
        (.center, abs((actualMin + actualMax) / 2 - (targetMin + targetMax) / 2)),
        (.max, abs(actualMax - targetMax))
    ]
    guard let closest = candidates.min(by: { $0.1 < $1.1 }), closest.1 <= edgeTolerance else {
        return nil
    }
    return MaximumConstraint(value: Double(actualLength), anchor: closest.0)
}

private func stricterMaximum(
    lhs: (value: Double?, anchor: WindowConstraintAnchor?),
    rhs: (value: Double?, anchor: WindowConstraintAnchor?)
) -> (value: Double?, anchor: WindowConstraintAnchor?) {
    switch (lhs.value, rhs.value) {
    case (.some(let left), .some(let right)) where right < left:
        return (right, rhs.anchor)
    case (.some(let left), .some):
        return (left, lhs.anchor)
    case (.some(let left), .none):
        return (left, lhs.anchor)
    case (.none, .some(let right)):
        return (right, rhs.anchor)
    case (.none, .none):
        return (nil, nil)
    }
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
