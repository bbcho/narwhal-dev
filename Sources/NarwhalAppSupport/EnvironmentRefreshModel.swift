import NarwhalCore

public struct EnvironmentRefreshResult: Equatable, Sendable {
    public let snapshot: EnvironmentSnapshot
    public let activeSpace: SpaceID?
    public let displayCount: Int
    public let windowCount: Int
    public let quality: AXSnapshotQuality
    public let preservedSpaceLayouts: Bool
    public let observedWindowCount: Int
    public let mappedWindowCount: Int

    public init(
        snapshot: EnvironmentSnapshot,
        activeSpace: SpaceID?,
        displayCount: Int,
        windowCount: Int,
        quality: AXSnapshotQuality,
        preservedSpaceLayouts: Bool,
        observedWindowCount: Int,
        mappedWindowCount: Int
    ) {
        self.snapshot = snapshot
        self.activeSpace = activeSpace
        self.displayCount = displayCount
        self.windowCount = windowCount
        self.quality = quality
        self.preservedSpaceLayouts = preservedSpaceLayouts
        self.observedWindowCount = observedWindowCount
        self.mappedWindowCount = mappedWindowCount
    }
}

public struct EnvironmentRefreshTransition: Equatable, Sendable {
    public let world: World
    public let result: EnvironmentRefreshResult

    public init(world: World, result: EnvironmentRefreshResult) {
        self.world = world
        self.result = result
    }
}

public func environmentRefreshTransition(
    for snapshot: EnvironmentSnapshot,
    in world: World
) -> EnvironmentRefreshTransition {
    let preservedSpaceLayouts = environmentSnapshotPreservesSpaceLayouts(snapshot, in: world)
    let refreshedWorld: World
    switch apply(.environmentChanged(snapshot), to: world) {
    case .success(let next):
        refreshedWorld = next
    case .failure:
        refreshedWorld = world
    }
    return EnvironmentRefreshTransition(
        world: refreshedWorld,
        result: EnvironmentRefreshResult(
            snapshot: snapshot,
            activeSpace: refreshedWorld.activeSpace,
            displayCount: refreshedWorld.displays.count,
            windowCount: refreshedWorld.windows.count,
            quality: snapshot.axSnapshot.quality,
            preservedSpaceLayouts: preservedSpaceLayouts,
            observedWindowCount: snapshot.observedWindowCount,
            mappedWindowCount: snapshot.mappedWindowCount
        )
    )
}
