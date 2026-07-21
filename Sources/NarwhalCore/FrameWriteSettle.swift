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
    guard abs(target.width - actual.width) <= maxDrift,
          abs(target.height - actual.height) <= maxDrift
    else {
        return false
    }
    guard expandedDimensionsAreEdgeNormalized(target: target, actual: actual, tolerance: tolerance) else {
        return false
    }

    let intersection = target.intersection(actual)
    guard intersection.narwhalIsFinitePositive else { return false }
    let overlapRatio = intersection.narwhalArea / min(target.narwhalArea, actual.narwhalArea)
    return overlapRatio >= CGFloat(min(max(0, minimumOverlapRatio), 1))
}

public func frameWriteContainmentCorrection(
    target: CGRect,
    actual: CGRect,
    tolerance: Double,
    containmentTolerance: Double = 0.5,
    correctionMargin: Double? = nil
) -> CGRect? {
    guard frameWriteApproximatelySettled(
        target: target,
        actual: actual,
        tolerance: tolerance
    ) else {
        return nil
    }

    let containmentTolerance = CGFloat(max(0, containmentTolerance))
    let leadingX = max(0, target.minX - actual.minX)
    let trailingX = max(0, actual.maxX - target.maxX)
    let leadingY = max(0, target.minY - actual.minY)
    let trailingY = max(0, actual.maxY - target.maxY)
    guard leadingX > containmentTolerance
            || trailingX > containmentTolerance
            || leadingY > containmentTolerance
            || trailingY > containmentTolerance
    else {
        return nil
    }

    let margin = CGFloat(max(0, correctionMargin ?? tolerance))
    let leadingXCorrection = leadingX > containmentTolerance ? leadingX + margin : 0
    let trailingXCorrection = trailingX > containmentTolerance ? trailingX + margin : 0
    let leadingYCorrection = leadingY > containmentTolerance ? leadingY + margin : 0
    let trailingYCorrection = trailingY > containmentTolerance ? trailingY + margin : 0
    let correction = CGRect(
        x: target.minX + leadingXCorrection,
        y: target.minY + leadingYCorrection,
        width: target.width - leadingXCorrection - trailingXCorrection,
        height: target.height - leadingYCorrection - trailingYCorrection
    )
    return correction.narwhalIsFinitePositive ? correction : nil
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
    let edgeTolerance = tolerance + 1
    return abs(upperDelta) <= edgeTolerance
        && abs(lowerDelta + expansion) <= edgeTolerance
}
