import Foundation

public enum LogLineLevel: String, Equatable, Sendable {
    case info
    case error
}

private struct LogRedaction {
    let expression: NSRegularExpression
    let replacement: String
}

private func logRedaction(_ pattern: String, replacement: String) -> LogRedaction {
    do {
        return LogRedaction(
            expression: try NSRegularExpression(pattern: pattern),
            replacement: replacement
        )
    } catch {
        preconditionFailure("Invalid built-in log redaction pattern: \(error)")
    }
}

private let logRedactions: [LogRedaction] = [
    logRedaction(
        #"(?s)title=\".*?\"(?=\s+(?:role|frame)=|\)|:)"#,
        replacement: "title=<redacted>"
    ),
    logRedaction(
        #"bundle=[^\s)]+"#,
        replacement: "bundle=<redacted>"
    ),
    logRedaction(
        #"(?<![A-Za-z0-9_/-])/(?!/)[^\s,;)]*"#,
        replacement: "<path>"
    )
]

/// `homeDirectory` is replaced first and literally: a path like
/// "/Users/Jane Doe/..." contains a space, which the path pattern would stop at,
/// leaking "Doe/...".
public func redactedLogMessage(_ message: String, homeDirectory: String? = nil) -> String {
    let withoutHome = homeDirectory.flatMap { $0.isEmpty ? nil : $0 }
        .map { home in
            // Only at a name boundary: home "/Users/Jane" must not rewrite "/Users/Janet".
            message.replacingOccurrences(
                of: NSRegularExpression.escapedPattern(for: home) + #"(?![A-Za-z0-9_-])"#,
                with: "~",
                options: .regularExpression
            )
        } ?? message
    return logRedactions.reduce(withoutHome) { redacted, redaction in
        let range = NSRange(redacted.startIndex..., in: redacted)
        return redaction.expression.stringByReplacingMatches(
            in: redacted,
            range: range,
            withTemplate: redaction.replacement
        )
    }
}

public func formattedLogLine(
    timestamp: String,
    level: LogLineLevel,
    message: String
) -> String {
    "\(timestamp) \(level.rawValue): \(message)\n"
}

public enum LogRotationOperation: Equatable, Sendable {
    case remove(generation: Int)
    case move(fromGeneration: Int, toGeneration: Int)
}

public func logRotationPlan(
    currentByteCount: UInt64,
    maximumByteCount: UInt64,
    retainedGenerationCount: Int
) -> [LogRotationOperation] {
    guard maximumByteCount > 0,
          currentByteCount >= maximumByteCount,
          retainedGenerationCount > 0
    else { return [] }

    var operations: [LogRotationOperation] = [
        .remove(generation: retainedGenerationCount)
    ]
    if retainedGenerationCount > 1 {
        for generation in stride(
            from: retainedGenerationCount - 1,
            through: 1,
            by: -1
        ) {
            operations.append(.move(
                fromGeneration: generation,
                toGeneration: generation + 1
            ))
        }
    }
    operations.append(.move(fromGeneration: 0, toGeneration: 1))
    return operations
}
