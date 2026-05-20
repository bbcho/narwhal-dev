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

public struct ConfigWatchTarget: Equatable, Sendable {
    public let configPath: String
    public let directoryPath: String

    public init(configPath: String, directoryPath: String) {
        self.configPath = configPath
        self.directoryPath = directoryPath
    }
}

public func configChangeEventTouchesTarget(
    path: String,
    target: ConfigWatchTarget
) -> Bool {
    path == target.configPath || path == target.directoryPath
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
