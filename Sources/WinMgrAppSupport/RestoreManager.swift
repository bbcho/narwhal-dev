import Foundation
import WinMgrCore

public enum RestoreManagerError: Error, CustomStringConvertible, Equatable {
    case decodeFailed(String)
    case invalidStoredWorld(String)

    public var description: String {
        switch self {
        case .decodeFailed(let message):
            return "restore JSON decode failed: \(message)"
        case .invalidStoredWorld(let message):
            return "restore JSON invalid: \(message)"
        }
    }
}

public struct RestoreManager {
    public static let defaultURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("winmgr", isDirectory: true)
        .appendingPathComponent("state.json", isDirectory: false)

    public let url: URL

    public init(url: URL = RestoreManager.defaultURL) {
        self.url = url
    }

    public func load() throws -> StoredWorld? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data = try Data(contentsOf: url)
        let stored: StoredWorld
        do {
            stored = try JSONDecoder().decode(StoredWorld.self, from: data)
        } catch {
            throw RestoreManagerError.decodeFailed(String(describing: error))
        }

        guard stored.schemaVersion == StoredWorld.currentSchemaVersion else {
            return nil
        }
        switch validateStoredWorld(stored) {
        case .success(let validated):
            return validated
        case .failure(.invalidStoredWorld(let message)):
            throw RestoreManagerError.invalidStoredWorld(message)
        }
    }

    public func save(_ stored: StoredWorld) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)
        try data.write(to: url, options: [.atomic])
    }
}
