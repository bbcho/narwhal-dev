import NarwhalCore

public enum HotkeyWorkspaceStabilityPolicy: Equatable, Sendable {
    case runImmediately
    case waitForStableWorkspace
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
