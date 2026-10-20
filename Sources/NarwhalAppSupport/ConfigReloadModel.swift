public struct ConfigReloadDebounceState: Equatable, Sendable {
    public static let empty = ConfigReloadDebounceState(nextGeneration: 1, pendingGeneration: nil)

    public let nextGeneration: UInt64
    public let pendingGeneration: UInt64?

    public init(nextGeneration: UInt64, pendingGeneration: UInt64?) {
        self.nextGeneration = nextGeneration
        self.pendingGeneration = pendingGeneration
    }
}

public enum ConfigReloadTimerDecision: Equatable, Sendable {
    case idle
    case stale(pendingGeneration: UInt64)
    case reload
}

/// The paths whose changes mean the config may have changed. FSEvents reports
/// symlink-resolved paths, so a symlinked config also lists its resolved paths.
public struct ConfigWatchTarget: Equatable, Sendable {
    public let configPath: String
    public let directoryPath: String
    public let resolvedConfigPath: String
    public let resolvedDirectoryPath: String

    public init(
        configPath: String,
        directoryPath: String,
        resolvedConfigPath: String? = nil,
        resolvedDirectoryPath: String? = nil
    ) {
        self.configPath = configPath
        self.directoryPath = directoryPath
        self.resolvedConfigPath = resolvedConfigPath ?? configPath
        self.resolvedDirectoryPath = resolvedDirectoryPath ?? directoryPath
    }
}

public struct ConfigWatchRootCandidate: Equatable, Sendable {
    public let path: String
    public let isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }
}

public func configChangeEventTouchesTarget(
    path: String,
    target: ConfigWatchTarget
) -> Bool {
    [target.configPath, target.directoryPath, target.resolvedConfigPath, target.resolvedDirectoryPath]
        .contains(path)
}

public func selectedConfigWatchRoot(
    from candidates: [ConfigWatchRootCandidate]
) -> String? {
    candidates.first { $0.isDirectory }?.path
}

public func scheduleConfigReload(
    in state: ConfigReloadDebounceState
) -> (state: ConfigReloadDebounceState, generation: UInt64) {
    let generation = state.nextGeneration
    return (
        ConfigReloadDebounceState(
            nextGeneration: state.nextGeneration + 1,
            pendingGeneration: generation
        ),
        generation
    )
}

public func fireConfigReloadTimer(
    generation: UInt64,
    in state: ConfigReloadDebounceState
) -> (state: ConfigReloadDebounceState, decision: ConfigReloadTimerDecision) {
    guard let pendingGeneration = state.pendingGeneration else {
        return (state, .idle)
    }
    guard pendingGeneration == generation else {
        return (state, .stale(pendingGeneration: pendingGeneration))
    }
    return (
        ConfigReloadDebounceState(
            nextGeneration: state.nextGeneration,
            pendingGeneration: nil
        ),
        .reload
    )
}

public func cancelConfigReload(in state: ConfigReloadDebounceState) -> ConfigReloadDebounceState {
    ConfigReloadDebounceState(nextGeneration: state.nextGeneration, pendingGeneration: nil)
}
