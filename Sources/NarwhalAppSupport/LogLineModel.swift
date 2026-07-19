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
