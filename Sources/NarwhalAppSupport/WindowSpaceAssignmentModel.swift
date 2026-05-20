import CoreGraphics
import NarwhalCore

public func spaceTopologyByMergingWindowSpaces(
    _ topology: SpaceTopology,
    windowSpaces: [WindowID: SpaceID]
) -> SpaceTopology {
    SpaceTopology(
        activeSpaceByDisplay: topology.activeSpaceByDisplay,
        windowSpace: topology.windowSpace.merging(windowSpaces) { _, live in live },
        quality: topology.quality
    )
}

public func selectedWindowSpace(
    for metadata: WindowMetadata,
    candidateSpaces: [SpaceID],
    displays: [DisplayID: DisplayInfo],
    activeSpaceByDisplay: [DisplayID: SpaceID]
) -> SpaceID? {
    guard !candidateSpaces.isEmpty else { return nil }
    if candidateSpaces.count == 1 {
        return candidateSpaces[0]
    }
    let displayID = displayContaining(frame: metadata.frame, displays: displays)
    if let displayID,
       let activeSpace = activeSpaceByDisplay[displayID],
       candidateSpaces.contains(activeSpace) {
        return activeSpace
    }
    return candidateSpaces.sorted { $0.raw < $1.raw }.first
}

public func displayContaining(
    frame: CGRect,
    displays: [DisplayID: DisplayInfo]
) -> DisplayID? {
    if let byIntersection = displays.max(by: { lhs, rhs in
        lhs.value.visibleFrame.intersection(frame).area < rhs.value.visibleFrame.intersection(frame).area
    }), byIntersection.value.visibleFrame.intersection(frame).area > 0 {
        return byIntersection.key
    }

    let center = CGPoint(x: frame.midX, y: frame.midY)
    return displays.min(by: { lhs, rhs in
        lhs.value.visibleFrame.center.distanceSquared(to: center) < rhs.value.visibleFrame.center.distanceSquared(to: center)
    })?.key
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
