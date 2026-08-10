import CoreGraphics

public enum GeometryTolerances {
    public static let frameWriteSettle: CGFloat = 4
    public static let configuredGap: CGFloat = 0.5
    public static let externalResizeDirection: CGFloat = 1
}

public let frameWriteSettleTolerance: CGFloat = GeometryTolerances.frameWriteSettle
public let configuredGapTolerance: CGFloat = GeometryTolerances.configuredGap

func splitFrames(_ frame: CGRect, axis: Axis, weights: [Double]) -> [CGRect] {
    let total = weights.reduce(0, +)
    guard total > 0 else { return [] }

    let lengths = splitLengths(
        extent: axis == .horizontal ? frame.width : frame.height,
        weights: weights,
        totalWeight: total
    )
    return framesFromLengths(frame, axis: axis, lengths: lengths)
}

func splitFrames(_ frame: CGRect, axis: Axis, lengths: [Double]) -> [CGRect] {
    framesFromLengths(frame, axis: axis, lengths: lengths.map { CGFloat($0) })
}

func applyOuterGaps(_ gaps: Insets, to frame: CGRect) -> CGRect {
    CGRect(
        x: frame.minX + gaps.left,
        y: frame.minY + gaps.top,
        width: max(0, frame.width - gaps.left - gaps.right),
        height: max(0, frame.height - gaps.top - gaps.bottom)
    )
}

public func displayContainingFrame(_ frame: CGRect, displays: [DisplayID: DisplayInfo]) -> DisplayID? {
    if let byIntersection = displays.max(by: { lhs, rhs in
        lhs.value.visibleFrame.intersection(frame).narwhalArea
            < rhs.value.visibleFrame.intersection(frame).narwhalArea
    }), byIntersection.value.visibleFrame.intersection(frame).narwhalArea > 0 {
        return byIntersection.key
    }

    let center = frame.narwhalCenter
    return displays.min(by: { lhs, rhs in
        lhs.value.visibleFrame.narwhalCenter.narwhalDistanceSquared(to: center)
            < rhs.value.visibleFrame.narwhalCenter.narwhalDistanceSquared(to: center)
    })?.key
}

private func splitLengths(extent: CGFloat, weights: [Double], totalWeight: Double) -> [CGFloat] {
    guard !weights.isEmpty else { return [] }
    let leading = weights.dropLast().map { extent * CGFloat($0 / totalWeight) }
    return leading + [extent - leading.reduce(0, +)]
}

private struct SplitFrameAccumulator {
    let idealOffset: CGFloat
    let renderedOffset: CGFloat
    let frames: [CGRect]
}

private func framesFromLengths(_ frame: CGRect, axis: Axis, lengths: [CGFloat]) -> [CGRect] {
    lengths.enumerated().reduce(SplitFrameAccumulator(idealOffset: 0, renderedOffset: 0, frames: [])) { state, entry in
        let (index, length) = entry
        let isLast = index == lengths.count - 1
        let idealBoundaryOffset = state.idealOffset + length
        switch axis {
        case .horizontal:
            let renderedBoundaryOffset = isLast
                ? frame.width
                : quantizedSplitBoundary(frame.minX + idealBoundaryOffset) - frame.minX
            let width = max(0, renderedBoundaryOffset - state.renderedOffset)
            return SplitFrameAccumulator(
                idealOffset: idealBoundaryOffset,
                renderedOffset: state.renderedOffset + width,
                frames: state.frames + [
                    CGRect(x: frame.minX + state.renderedOffset, y: frame.minY, width: width, height: frame.height)
                ]
            )
        case .vertical:
            let renderedBoundaryOffset = isLast
                ? frame.height
                : quantizedSplitBoundary(frame.minY + idealBoundaryOffset) - frame.minY
            let height = max(0, renderedBoundaryOffset - state.renderedOffset)
            return SplitFrameAccumulator(
                idealOffset: idealBoundaryOffset,
                renderedOffset: state.renderedOffset + height,
                frames: state.frames + [
                    CGRect(x: frame.minX, y: frame.minY + state.renderedOffset, width: frame.width, height: height)
                ]
            )
        }
    }.frames
}

func quantizedSplitBoundary(_ value: CGFloat) -> CGFloat {
    let nearestInteger = value.rounded()
    let floatingPointNoise = max(1, abs(value)) * CGFloat.ulpOfOne * 16
    if abs(value - nearestInteger) <= floatingPointNoise {
        return nearestInteger
    }
    return value.rounded(.up)
}

public extension CGRect {
    var narwhalArea: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    var narwhalCenter: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var narwhalIsFinitePositive: Bool {
        !isNull
            && !isInfinite
            && minX.isFinite
            && minY.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
    }

    func narwhalApproximatelyEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        let tolerance = max(0, tolerance)
        return abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    func narwhalFills(_ other: CGRect, tolerance: CGFloat, minimumAreaRatio: CGFloat) -> Bool {
        guard narwhalIsFinitePositive, other.narwhalIsFinitePositive else { return false }
        let tolerance = max(0, tolerance)
        let expanded = other.insetBy(dx: -tolerance, dy: -tolerance)
        guard minX >= expanded.minX,
              minY >= expanded.minY,
              maxX <= expanded.maxX,
              maxY <= expanded.maxY
        else {
            return false
        }
        return narwhalArea / other.narwhalArea >= minimumAreaRatio
    }
}

public extension CGSize {
    var narwhalIsFinitePositive: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }

    func narwhalApproximatelyEquals(_ other: CGSize, tolerance: CGFloat) -> Bool {
        let tolerance = max(0, tolerance)
        return abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

public extension CGPoint {
    func narwhalApproximatelyEquals(_ other: CGPoint, tolerance: CGFloat) -> Bool {
        let tolerance = max(0, tolerance)
        return abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
    }

    func narwhalDistanceSquared(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
