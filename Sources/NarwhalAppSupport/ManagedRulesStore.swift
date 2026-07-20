import Foundation
import NarwhalCore

public enum ManagedRulesStoreError: Error, CustomStringConvertible, Equatable, Sendable {
    case fileTooLarge(bytes: Int, limit: Int)
    case decodeFailed(String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case tooManyRules(found: Int, limit: Int)
    case invalidRules(ManagedRuleValidationError)

    public var description: String {
        switch self {
        case .fileTooLarge(let bytes, let limit):
            return "managed rules file is \(bytes) bytes; limit is \(limit)"
        case .decodeFailed(let message):
            return "managed rules JSON decode failed: \(message)"
        case .unsupportedSchemaVersion(let found, let supported):
            return "managed rules schema version \(found) is unsupported; this build supports version \(supported)"
        case .tooManyRules(let found, let limit):
            return "managed rules contains \(found) rules; limit is \(limit)"
        case .invalidRules(let error):
            return "managed rules validation failed: \(error)"
        }
    }
}

public struct ManagedRulesRecovery: Equatable, Sendable {
    public let error: ManagedRulesStoreError
    public let quarantinedFilename: String

    public init(error: ManagedRulesStoreError, quarantinedFilename: String) {
        self.error = error
        self.quarantinedFilename = quarantinedFilename
    }
}

public enum ManagedRulesLoadOutcome: Equatable, Sendable {
    case missing
    case loaded([ManagedWindowRule])
    case recoveredEmpty(ManagedRulesRecovery)
    case incompatible(ManagedRulesStoreError)
}

public struct StoredManagedRules: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let rules: [ManagedWindowRule]

    public init(schemaVersion: Int = currentSchemaVersion, rules: [ManagedWindowRule]) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }
}

public struct ManagedRulesStore: Sendable {
    public static let maximumFileSize = 1_048_576
    public static let maximumRuleCount = 256
    public static let defaultURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("narwhal", isDirectory: true)
        .appendingPathComponent("managed-rules.json", isDirectory: false)

    public let url: URL

    public init(url: URL = ManagedRulesStore.defaultURL) {
        self.url = url
    }

    public func loadRecovering(quarantineID: String = UUID().uuidString) throws -> ManagedRulesLoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

        do {
            return .loaded(try load())
        } catch let error as ManagedRulesStoreError {
            if case .unsupportedSchemaVersion = error {
                return .incompatible(error)
            }
            let destination = try quarantine(id: quarantineID)
            return .recoveredEmpty(ManagedRulesRecovery(
                error: error,
                quarantinedFilename: destination.lastPathComponent
            ))
        }
    }

    public func load() throws -> [ManagedWindowRule] {
        let data = try readPrivateArtifact(
            at: url,
            maximumSize: Self.maximumFileSize,
            fileTooLarge: { ManagedRulesStoreError.fileTooLarge(bytes: $0, limit: $1) }
        )
        return try decodeStoredManagedRules(data).rules
    }

    public func save(_ rules: [ManagedWindowRule]) throws {
        let stored = try validated(StoredManagedRules(rules: rules))
        try writePrivateArtifact(encode(stored), to: url)
    }

    private func quarantine(id: String) throws -> URL {
        try quarantinePrivateArtifact(at: url, id: id)
    }
}

func decodeStoredManagedRules(_ data: Data) throws -> StoredManagedRules {
    guard data.count <= ManagedRulesStore.maximumFileSize else {
        throw ManagedRulesStoreError.fileTooLarge(
            bytes: data.count,
            limit: ManagedRulesStore.maximumFileSize
        )
    }
    let stored: StoredManagedRules
    do {
        stored = try JSONDecoder().decode(StoredManagedRules.self, from: data)
    } catch {
        throw ManagedRulesStoreError.decodeFailed(String(describing: error))
    }
    return try validated(stored)
}

private func validated(_ stored: StoredManagedRules) throws -> StoredManagedRules {
    guard stored.schemaVersion == StoredManagedRules.currentSchemaVersion else {
        throw ManagedRulesStoreError.unsupportedSchemaVersion(
            found: stored.schemaVersion,
            supported: StoredManagedRules.currentSchemaVersion
        )
    }
    guard stored.rules.count <= ManagedRulesStore.maximumRuleCount else {
        throw ManagedRulesStoreError.tooManyRules(
            found: stored.rules.count,
            limit: ManagedRulesStore.maximumRuleCount
        )
    }
    switch validateManagedRules(stored.rules) {
    case .success:
        return stored
    case .failure(let error):
        throw ManagedRulesStoreError.invalidRules(error)
    }
}

private func encode(_ stored: StoredManagedRules) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(stored)
}
