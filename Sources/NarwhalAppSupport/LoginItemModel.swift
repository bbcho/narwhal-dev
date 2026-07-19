public enum LoginItemStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
    case failed(String)

    public var menuTitle: String {
        switch self {
        case .disabled, .enabled:
            return "Launch at Login"
        case .requiresApproval:
            return "Launch at Login (Approval Required)"
        case .unavailable:
            return "Launch at Login (Unavailable)"
        case .failed:
            return "Launch at Login (Error)"
        }
    }

    public var isEnabled: Bool {
        self == .enabled
    }

    public var canPerformAction: Bool {
        self != .unavailable
    }
}
