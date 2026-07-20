import Foundation
import NarwhalCore

public enum NamedLayoutsStoreError: Error, CustomStringConvertible, Equatable, Sendable {
    case fileTooLarge(bytes: Int, limit: Int)
    case decodeFailed(String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case tooManyLayouts(found: Int, limit: Int)
    case duplicateLayoutID(NamedLayoutID)
    case invalidLayout(id: NamedLayoutID, error: NamedLayoutValidationError)

    public var description: String {
        switch self {
        case .fileTooLarge(let bytes, let limit):
            return "named layouts file is \(bytes) bytes; limit is \(limit)"
        case .decodeFailed(let message):
            return "named layouts JSON decode failed: \(message)"
        case .unsupportedSchemaVersion(let found, let supported):
            return "named layouts schema version \(found) is unsupported; this build supports version \(supported)"
        case .tooManyLayouts(let found, let limit):
            return "named layouts contains \(found) layouts; limit is \(limit)"
        case .duplicateLayoutID(let id):
            return "named layouts repeats layout id \(id.rawValue)"
        case .invalidLayout(let id, let error):
            return "named layout \(id.rawValue) is invalid: \(error)"
        }
    }
}

public struct NamedLayoutsRecovery: Equatable, Sendable {
    public let error: NamedLayoutsStoreError
    public let quarantinedFilename: String

    public init(error: NamedLayoutsStoreError, quarantinedFilename: String) {
        self.error = error
        self.quarantinedFilename = quarantinedFilename
    }
}

public enum NamedLayoutsLoadOutcome: Equatable, Sendable {
    case missing
    case loaded([NamedLayout])
    case recoveredEmpty(NamedLayoutsRecovery)
    case incompatible(NamedLayoutsStoreError)
}

public struct StoredNamedLayouts: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let layouts: [NamedLayout]

    public init(schemaVersion: Int = currentSchemaVersion, layouts: [NamedLayout]) {
        self.schemaVersion = schemaVersion
        self.layouts = layouts
    }
}

public struct NamedLayoutsStore: Sendable {
    public static let maximumFileSize = 2_097_152
    public static let maximumLayoutCount = 64
    public static let defaultURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("narwhal", isDirectory: true)
        .appendingPathComponent("layouts.json", isDirectory: false)

    public let url: URL

    public init(url: URL = NamedLayoutsStore.defaultURL) {
        self.url = url
    }

    public func loadRecovering(quarantineID: String = UUID().uuidString) throws -> NamedLayoutsLoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

        do {
            return .loaded(try load())
        } catch let error as NamedLayoutsStoreError {
            if case .unsupportedSchemaVersion = error {
                return .incompatible(error)
            }
            let destination = try quarantine(id: quarantineID)
            return .recoveredEmpty(NamedLayoutsRecovery(
                error: error,
                quarantinedFilename: destination.lastPathComponent
            ))
        }
    }

    public func load() throws -> [NamedLayout] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let byteCount = attributes[.size] as? NSNumber,
           byteCount.intValue > Self.maximumFileSize {
            throw NamedLayoutsStoreError.fileTooLarge(
                bytes: byteCount.intValue,
                limit: Self.maximumFileSize
            )
        }
        return try decodeStoredNamedLayouts(Data(contentsOf: url)).layouts
    }

    public func save(_ layouts: [NamedLayout]) throws {
        let stored = try validated(StoredNamedLayouts(layouts: layouts))
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try encode(stored).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func quarantine(id: String) throws -> URL {
        let destination = url
            .deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(id)")
        try FileManager.default.moveItem(at: url, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }
}

func decodeStoredNamedLayouts(_ data: Data) throws -> StoredNamedLayouts {
    guard data.count <= NamedLayoutsStore.maximumFileSize else {
        throw NamedLayoutsStoreError.fileTooLarge(bytes: data.count, limit: NamedLayoutsStore.maximumFileSize)
    }
    let stored: StoredNamedLayouts
    do {
        stored = try JSONDecoder().decode(StoredNamedLayouts.self, from: data)
    } catch {
        throw NamedLayoutsStoreError.decodeFailed(String(describing: error))
    }
    return try validated(stored)
}

private func validated(_ stored: StoredNamedLayouts) throws -> StoredNamedLayouts {
    guard stored.schemaVersion == StoredNamedLayouts.currentSchemaVersion else {
        throw NamedLayoutsStoreError.unsupportedSchemaVersion(
            found: stored.schemaVersion,
            supported: StoredNamedLayouts.currentSchemaVersion
        )
    }
    guard stored.layouts.count <= NamedLayoutsStore.maximumLayoutCount else {
        throw NamedLayoutsStoreError.tooManyLayouts(
            found: stored.layouts.count,
            limit: NamedLayoutsStore.maximumLayoutCount
        )
    }

    var ids = Set<NamedLayoutID>()
    for layout in stored.layouts {
        guard ids.insert(layout.id).inserted else {
            throw NamedLayoutsStoreError.duplicateLayoutID(layout.id)
        }
        if case .failure(let error) = validateNamedLayout(layout) {
            throw NamedLayoutsStoreError.invalidLayout(id: layout.id, error: error)
        }
    }
    return stored
}

private func encode(_ stored: StoredNamedLayouts) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(stored)
}
