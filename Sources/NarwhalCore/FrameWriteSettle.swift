import CoreGraphics

public let frameWriteSettleTolerance: CGFloat = 4

public func frameWriteApproximatelySettled(
    target: CGRect,
    actual: CGRect,
    tolerance: Double,
    maxEdgeDrift: Double = 48,
    minimumOverlapRatio: Double = 0.90
) -> Bool {
    let tolerance = CGFloat(max(0, tolerance))
    if framesApproximatelyMatch(target, actual, tolerance: tolerance) {
        return true
    }
    guard target.isUsableFrame, actual.isUsableFrame else { return false }
    guard inferObservedConstraints(target: target, actual: actual, tolerance: Double(tolerance)) == nil else {
        return false
    }

    let maxDrift = CGFloat(max(0, maxEdgeDrift))
    let edgesAreClose = abs(target.minX - actual.minX) <= maxDrift
        && abs(target.minY - actual.minY) <= maxDrift
        && abs(target.maxX - actual.maxX) <= maxDrift
        && abs(target.maxY - actual.maxY) <= maxDrift
    guard edgesAreClose else { return false }

    let intersection = target.intersection(actual)
    guard intersection.isUsableFrame else { return false }
    let overlapRatio = intersection.area / min(target.area, actual.area)
    return overlapRatio >= CGFloat(min(max(0, minimumOverlapRatio), 1))
}

public func frameSizeApproximatelySettled(
    target: CGSize,
    actual: CGSize,
    tolerance: Double,
    maxDimensionDrift: Double = 48
) -> Bool {
    let tolerance = CGFloat(max(0, tolerance))
    if sizesApproximatelyMatch(target, actual, tolerance: tolerance) {
        return true
    }
    guard target.isUsableSize, actual.isUsableSize else { return false }
    guard actual.width <= target.width + tolerance,
          actual.height <= target.height + tolerance
    else {
        return false
    }

    let maxDrift = CGFloat(max(0, maxDimensionDrift))
    return abs(target.width - actual.width) <= maxDrift
        && abs(target.height - actual.height) <= maxDrift
}

private func framesApproximatelyMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
        && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

private func sizesApproximatelyMatch(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat) -> Bool {
    abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

private extension CGRect {
    var isUsableFrame: Bool {
        !isNull
            && !isInfinite
            && origin.x.isFinite
            && origin.y.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
    }

    var area: CGFloat {
        width * height
    }
}

private extension CGSize {
    var isUsableSize: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
