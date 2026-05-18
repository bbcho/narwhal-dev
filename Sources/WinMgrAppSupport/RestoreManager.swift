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

public struct RestoreManager: Sendable {
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

public struct RestoreSaveSuccess: Equatable, Sendable {
    public let generation: UInt64
    public let reason: String
    public let urlPath: String

    public init(generation: UInt64, reason: String, urlPath: String) {
        self.generation = generation
        self.reason = reason
        self.urlPath = urlPath
    }
}

public struct RestoreSaveFailure: Equatable, Sendable {
    public let generation: UInt64
    public let reason: String
    public let urlPath: String
    public let message: String

    public init(generation: UInt64, reason: String, urlPath: String, message: String) {
        self.generation = generation
        self.reason = reason
        self.urlPath = urlPath
        self.message = message
    }
}

public enum RestoreSaveEvent: Equatable, Sendable {
    case saved(RestoreSaveSuccess)
    case failed(RestoreSaveFailure)
}

public actor RestoreSaveScheduler {
    public typealias Save = @Sendable (StoredWorld) throws -> Void
    public typealias Observe = @Sendable (RestoreSaveEvent) async -> Void

    private struct PendingSave: Sendable {
        let generation: UInt64
        let stored: StoredWorld
        let reason: String
    }

    private let urlPath: String
    private let debounceNanoseconds: UInt64
    private let save: Save
    private let observe: Observe
    private var nextGeneration: UInt64 = 0
    private var pending: PendingSave?
    private var scheduledTask: Task<Void, Never>?

    public init(
        manager: RestoreManager,
        debounceNanoseconds: UInt64 = 250_000_000,
        observe: @escaping Observe = { _ in }
    ) {
        self.init(
            urlPath: manager.url.path,
            debounceNanoseconds: debounceNanoseconds,
            save: { stored in
                try manager.save(stored)
            },
            observe: observe
        )
    }

    public init(
        urlPath: String,
        debounceNanoseconds: UInt64,
        save: @escaping Save,
        observe: @escaping Observe = { _ in }
    ) {
        self.urlPath = urlPath
        self.debounceNanoseconds = debounceNanoseconds
        self.save = save
        self.observe = observe
    }

    public func scheduleSave(_ stored: StoredWorld, reason: String) {
        nextGeneration += 1
        let scheduled = PendingSave(generation: nextGeneration, stored: stored, reason: reason)
        pending = scheduled

        scheduledTask?.cancel()
        scheduledTask = Task { [debounceNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }
            await self.flushIfCurrent(generation: scheduled.generation)
        }
    }

    public func flushPending() async {
        scheduledTask?.cancel()
        scheduledTask = nil
        guard let current = pending else { return }
        pending = nil
        await saveAndObserve(current)
    }

    public func cancelPending() {
        scheduledTask?.cancel()
        scheduledTask = nil
        pending = nil
    }

    private func flushIfCurrent(generation: UInt64) async {
        guard let current = pending, current.generation == generation else { return }
        scheduledTask = nil
        pending = nil
        await saveAndObserve(current)
    }

    private func saveAndObserve(_ current: PendingSave) async {
        do {
            try save(current.stored)
            await observe(.saved(RestoreSaveSuccess(
                generation: current.generation,
                reason: current.reason,
                urlPath: urlPath
            )))
        } catch {
            await observe(.failed(RestoreSaveFailure(
                generation: current.generation,
                reason: current.reason,
                urlPath: urlPath,
                message: String(describing: error)
            )))
        }
    }
}
