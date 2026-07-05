import CoreGraphics
import NarwhalCore

public struct WindowSpaceCandidate: Equatable, Sendable {
    public let metadata: WindowMetadata
    public let candidateSpaces: [SpaceID]

    public init(metadata: WindowMetadata, candidateSpaces: [SpaceID]) {
        self.metadata = metadata
        self.candidateSpaces = candidateSpaces
    }
}

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

public func assignedWindowSpaces(
    from candidates: [WindowSpaceCandidate],
    displays: [DisplayID: DisplayInfo],
    activeSpaceByDisplay: [DisplayID: SpaceID]
) -> [WindowID: SpaceID] {
    Dictionary(
        candidates.compactMap { candidate -> (WindowID, SpaceID)? in
            selectedWindowSpace(
                for: candidate.metadata,
                candidateSpaces: candidate.candidateSpaces,
                displays: displays,
                activeSpaceByDisplay: activeSpaceByDisplay
            ).map { selected in (candidate.metadata.id, selected) }
        },
        uniquingKeysWith: { _, replacement in replacement }
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
    let displayID = displayContainingFrame(metadata.frame, displays: displays)
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
    displayContainingFrame(frame, displays: displays)
}
