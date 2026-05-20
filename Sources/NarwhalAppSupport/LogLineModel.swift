public enum LogLineLevel: String, Equatable, Sendable {
    case info
    case error
}

public func formattedLogLine(
    timestamp: String,
    level: LogLineLevel,
    message: String
) -> String {
    "\(timestamp) \(level.rawValue): \(message)\n"
}
