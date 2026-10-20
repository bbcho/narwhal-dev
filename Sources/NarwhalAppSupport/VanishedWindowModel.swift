import NarwhalCore

/// Why a window left the on-screen inventory.
public enum VanishedWindowFate: Equatable, Sendable {
    /// The WindowServer no longer has it.
    case closed
    /// Minimized or its app hidden: it keeps its tile slot until it returns.
    case parked
    /// Still exists elsewhere, such as on another Space.
    case offscreen
}

/// `existingWindowIDs` is every window the WindowServer still has, on any
/// Space; nil when it could not be read, which must never close a window.
public func vanishedWindowFate(
    _ windowID: WindowID,
    existingWindowIDs: Set<WindowID>?,
    isMinimizedOrHidden: Bool
) -> VanishedWindowFate {
    guard let existingWindowIDs else { return .offscreen }
    guard existingWindowIDs.contains(windowID) else { return .closed }
    return isMinimizedOrHidden ? .parked : .offscreen
}
