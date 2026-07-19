import NarwhalCore

public enum HotkeyWorkspaceStabilityPolicy: Equatable, Sendable {
    case runImmediately
    case waitForStableWorkspace
}

public struct HotkeyExecutionBatch: Equatable, Sendable {
    public let action: HotkeyAction
    public let resizeDeltas: [Double]
    public let consumedCount: Int

    public init(action: HotkeyAction, resizeDeltas: [Double], consumedCount: Int) {
        self.action = action
        self.resizeDeltas = resizeDeltas
        self.consumedCount = consumedCount
    }
}

public func nextHotkeyExecutionBatch(in pending: [HotkeyAction]) -> HotkeyExecutionBatch? {
    guard let first = pending.first else { return nil }
    guard case .command(.resizeSplit(let direction, _)) = first else {
        return HotkeyExecutionBatch(action: first, resizeDeltas: [], consumedCount: 1)
    }

    let matchingPrefix = pending.prefix { action in
        guard case .command(.resizeSplit(let candidateDirection, _)) = action else { return false }
        return candidateDirection == direction
    }
    let deltas = matchingPrefix.compactMap { action -> Double? in
        guard case .command(.resizeSplit(_, let delta)) = action else { return nil }
        return delta
    }
    return HotkeyExecutionBatch(action: first, resizeDeltas: deltas, consumedCount: matchingPrefix.count)
}

public func workspaceStabilityPolicy(for action: HotkeyAction) -> HotkeyWorkspaceStabilityPolicy {
    switch action {
    case .command(let template):
        switch template {
        case .togglePause, .resetLayout:
            return .runImmediately
        case .push,
             .center,
             .eject,
             .swap,
             .resizeSplit,
             .toggleFloat,
             .balance,
             .shuffle,
             .cascade,
             .maximizeReset,
             .undoLayout,
             .moveToNextDisplay,
             .focusDirection,
             .focusCycle,
             .focusPrevious:
            return .waitForStableWorkspace
        }
    case .openFinderWindow, .reloadConfig, .showCommands:
        return .runImmediately
    }
}
