public enum RuntimeReadinessIssue: Equatable, Sendable {
    case configFallback
    case configReloadFailed
    case activeSpaceUnavailable
    case restoreRecovered(quarantinedFilenames: [String])
    case restoreReset(quarantinedFilenames: [String])
    case restoreIncompatible
    case restoreUnavailable
    case serviceStartupFailed(service: String)

    public var summary: String {
        switch self {
        case .configFallback:
            return "using built-in config"
        case .configReloadFailed:
            return "last config reload failed"
        case .activeSpaceUnavailable:
            return "active Space unavailable"
        case .restoreRecovered:
            return "restore recovered from backup"
        case .restoreReset:
            return "invalid restore quarantined"
        case .restoreIncompatible:
            return "restore requires a newer Narwhal"
        case .restoreUnavailable:
            return "restore storage unavailable"
        case .serviceStartupFailed(let service):
            return "\(service) failed to start"
        }
    }
}

public enum RuntimeReadiness: Equatable, Sendable {
    case starting
    case waitingForAccessibility
    case operational
    case operationalWithWarning(RuntimeReadinessIssue)
    case degraded(RuntimeReadinessIssue)

    public var canRetryStartup: Bool {
        switch self {
        case .waitingForAccessibility, .degraded:
            return true
        case .starting, .operational, .operationalWithWarning:
            return false
        }
    }

    public var summary: String {
        switch self {
        case .starting:
            return "starting"
        case .waitingForAccessibility:
            return "waiting for Accessibility"
        case .operational:
            return "operational"
        case .operationalWithWarning(let issue):
            return "operational - \(issue.summary)"
        case .degraded(let issue):
            return "degraded - \(issue.summary)"
        }
    }
}
