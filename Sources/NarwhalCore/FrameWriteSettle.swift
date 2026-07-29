import CoreGraphics

public func frameWriteApproximatelySettled(
    target: CGRect,
    actual: CGRect,
    tolerance: Double,
    maxEdgeDrift: Double = 48,
    minimumOverlapRatio: Double = 0.90
) -> Bool {
    guard frameWriteNearTarget(
        target: target,
        actual: actual,
        tolerance: tolerance,
        maxEdgeDrift: maxEdgeDrift,
        minimumOverlapRatio: minimumOverlapRatio
    ) else {
        return false
    }
    return expandedDimensionsAreEdgeNormalized(
        target: target,
        actual: actual,
        tolerance: CGFloat(max(0, tolerance))
    )
}

public func frameWriteNearTarget(
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
    guard target.narwhalIsFinitePositive, actual.narwhalIsFinitePositive else {
        return nil
    }

    let tolerance = CGFloat(max(0, tolerance))
    let leadingX = max(0, target.minX - actual.minX)
    let trailingX = max(0, actual.maxX - target.maxX)
    let leadingY = max(0, target.minY - actual.minY)
    let trailingY = max(0, actual.maxY - target.maxY)
    let maximumRoundingOverflow = max(tolerance * 2, 12)
    let canRetrySmallOverflow = [leadingX, trailingX, leadingY, trailingY]
        .allSatisfy { $0 <= maximumRoundingOverflow }
    guard canRetrySmallOverflow || frameWriteApproximatelySettled(
        target: target,
        actual: actual,
        tolerance: Double(tolerance)
    ) else {
        return nil
    }

    let containmentTolerance = CGFloat(max(0, containmentTolerance))
    guard leadingX > containmentTolerance
            || trailingX > containmentTolerance
            || leadingY > containmentTolerance
            || trailingY > containmentTolerance
    else {
        return nil
    }

    let margin = CGFloat(max(0, correctionMargin ?? Double(tolerance)))
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

public func frameWriteGridSnapSettled(
    target: CGRect,
    actual: CGRect,
    tolerance: Double,
    maximumExpansion: Double = 12,
    maximumDimensionDrift: Double = 48
) -> Bool {
    guard target.narwhalIsFinitePositive, actual.narwhalIsFinitePositive else { return false }
    let tolerance = CGFloat(max(0, tolerance))
    let maximumExpansion = CGFloat(max(0, maximumExpansion))
    let maximumDimensionDrift = CGFloat(max(0, maximumDimensionDrift))
    func dimensionSettled(
        targetMin: CGFloat,
        targetMax: CGFloat,
        targetLength: CGFloat,
        actualMin: CGFloat,
        actualMax: CGFloat,
        actualLength: CGFloat
    ) -> Bool {
        guard abs(targetLength - actualLength) <= maximumDimensionDrift,
              actualLength - targetLength <= maximumExpansion
        else {
            return false
        }
        return abs(targetMin - actualMin) <= tolerance
            || abs(targetMax - actualMax) <= tolerance
    }
    return dimensionSettled(
        targetMin: target.minX,
        targetMax: target.maxX,
        targetLength: target.width,
        actualMin: actual.minX,
        actualMax: actual.maxX,
        actualLength: actual.width
    ) && dimensionSettled(
        targetMin: target.minY,
        targetMax: target.maxY,
        targetLength: target.height,
        actualMin: actual.minY,
        actualMax: actual.maxY,
        actualLength: actual.height
    )
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
