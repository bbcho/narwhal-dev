import CoreGraphics

public func frameWriteApproximatelySettled(
    target: CGRect,
    actual: CGRect,
    tolerance: Double,
    maxEdgeDrift: Double = 48,
    minimumOverlapRatio: Double = 0.90
) -> Bool {
    let tolerance = CGFloat(max(0, tolerance))
    if target.narwhalApproximatelyEquals(actual, tolerance: tolerance) {
        return true
    }
    guard target.narwhalIsFinitePositive, actual.narwhalIsFinitePositive else { return false }

    let maxDrift = CGFloat(max(0, maxEdgeDrift))
    let edgesAreClose = abs(target.minX - actual.minX) <= maxDrift
        && abs(target.minY - actual.minY) <= maxDrift
        && abs(target.maxX - actual.maxX) <= maxDrift
        && abs(target.maxY - actual.maxY) <= maxDrift
    guard edgesAreClose else { return false }
    guard expandedDimensionsAreEdgeNormalized(target: target, actual: actual, tolerance: tolerance) else {
        return false
    }

    let intersection = target.intersection(actual)
    guard intersection.narwhalIsFinitePositive else { return false }
    let overlapRatio = intersection.narwhalArea / min(target.narwhalArea, actual.narwhalArea)
    return overlapRatio >= CGFloat(min(max(0, minimumOverlapRatio), 1))
}

public func frameSizeApproximatelySettled(
    target: CGSize,
    actual: CGSize,
    tolerance: Double,
    maxDimensionDrift: Double = 48
) -> Bool {
    let tolerance = CGFloat(max(0, tolerance))
    if target.narwhalApproximatelyEquals(actual, tolerance: tolerance) {
        return true
    }
    guard target.narwhalIsFinitePositive, actual.narwhalIsFinitePositive else { return false }
    guard actual.width <= target.width + tolerance,
          actual.height <= target.height + tolerance
    else {
        return false
    }

    let maxDrift = CGFloat(max(0, maxDimensionDrift))
    return abs(target.width - actual.width) <= maxDrift
        && abs(target.height - actual.height) <= maxDrift
}

private func expandedDimensionsAreEdgeNormalized(target: CGRect, actual: CGRect, tolerance: CGFloat) -> Bool {
    dimensionExpansionIsEdgeNormalized(
        targetLower: target.minX,
        targetUpper: target.maxX,
        targetLength: target.width,
        actualLower: actual.minX,
        actualUpper: actual.maxX,
        actualLength: actual.width,
        tolerance: tolerance
    )
        && dimensionExpansionIsEdgeNormalized(
            targetLower: target.minY,
            targetUpper: target.maxY,
            targetLength: target.height,
            actualLower: actual.minY,
            actualUpper: actual.maxY,
            actualLength: actual.height,
            tolerance: tolerance
        )
}

private func dimensionExpansionIsEdgeNormalized(
    targetLower: CGFloat,
    targetUpper: CGFloat,
    targetLength: CGFloat,
    actualLower: CGFloat,
    actualUpper: CGFloat,
    actualLength: CGFloat,
    tolerance: CGFloat
) -> Bool {
    let expansion = actualLength - targetLength
    guard expansion > tolerance else { return true }

    let maximumEdgeNormalizationExpansion = max(tolerance * 2, 12)
    guard expansion <= maximumEdgeNormalizationExpansion else { return false }

    let lowerDelta = actualLower - targetLower
    let upperDelta = actualUpper - targetUpper
    return abs(upperDelta) <= tolerance
        && abs(lowerDelta + expansion) <= tolerance
}
