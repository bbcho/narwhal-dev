import Foundation
import NarwhalCore

public enum RestoreManagerError: Error, CustomStringConvertible, Equatable {
    case decodeFailed(String)
    case invalidStoredWorld(String)
    case unsupportedSchemaVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .decodeFailed(let message):
            return "restore JSON decode failed: \(message)"
        case .invalidStoredWorld(let message):
            return "restore JSON invalid: \(message)"
        case .unsupportedSchemaVersion(let found, let supported):
            return "restore JSON schema version \(found) is unsupported; this build supports version \(supported)"
        }
    }
}

public struct RestoreManager: Sendable {
    public static let defaultURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("narwhal", isDirectory: true)
        .appendingPathComponent("state.json", isDirectory: false)

    public let url: URL

    public init(url: URL = RestoreManager.defaultURL) {
        self.url = url
    }

    public func load() throws -> StoredWorld? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data = try Data(contentsOf: url)
        return try decodeStoredWorldRestoreData(data).get()
    }

    public func save(_ stored: StoredWorld) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try encodeStoredWorldRestoreData(stored).write(to: url, options: [.atomic])
    }
}

func decodeStoredWorldRestoreData(_ data: Data) -> Result<StoredWorld?, RestoreManagerError> {
    let stored: StoredWorld
    do {
        stored = try JSONDecoder().decode(StoredWorld.self, from: data)
    } catch {
        return .failure(.decodeFailed(String(describing: error)))
    }

    guard stored.schemaVersion == StoredWorld.currentSchemaVersion else {
        return .failure(.unsupportedSchemaVersion(
            found: stored.schemaVersion,
            supported: StoredWorld.currentSchemaVersion
        ))
    }
    switch validateStoredWorld(stored) {
    case .success(let validated):
        return .success(validated)
    case .failure(.invalidStoredWorld(let message)):
        return .failure(.invalidStoredWorld(message))
    }
}

func encodeStoredWorldRestoreData(_ stored: StoredWorld) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(stored)
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

public struct RestoreSaveRequest: Equatable, Sendable {
    public let generation: UInt64
    public let stored: StoredWorld
    public let reason: String

    public init(generation: UInt64, stored: StoredWorld, reason: String) {
        self.generation = generation
        self.stored = stored
        self.reason = reason
    }
}

public struct RestoreSaveSchedulerState: Equatable, Sendable {
    public static let empty = RestoreSaveSchedulerState(nextGeneration: 1, pending: nil)

    public let nextGeneration: UInt64
    public let pending: RestoreSaveRequest?

    public init(nextGeneration: UInt64, pending: RestoreSaveRequest?) {
        self.nextGeneration = nextGeneration
        self.pending = pending
    }
}

public enum RestoreSaveTimerDecision: Equatable, Sendable {
    case idle
    case stale(pending: RestoreSaveRequest)
    case save(RestoreSaveRequest)
}

public func scheduleRestoreSave(
    _ stored: StoredWorld,
    reason: String,
    in state: RestoreSaveSchedulerState
) -> (state: RestoreSaveSchedulerState, request: RestoreSaveRequest) {
    let request = RestoreSaveRequest(
        generation: state.nextGeneration,
        stored: stored,
        reason: reason
    )
    return (
        RestoreSaveSchedulerState(
            nextGeneration: state.nextGeneration + 1,
            pending: request
        ),
        request
    )
}

public func fireRestoreSaveTimer(
    generation: UInt64,
    in state: RestoreSaveSchedulerState
) -> (state: RestoreSaveSchedulerState, decision: RestoreSaveTimerDecision) {
    guard let pending = state.pending else {
        return (state, .idle)
    }
    guard pending.generation == generation else {
        return (state, .stale(pending: pending))
    }
    return (
        RestoreSaveSchedulerState(nextGeneration: state.nextGeneration, pending: nil),
        .save(pending)
    )
}

public func flushRestoreSave(
    in state: RestoreSaveSchedulerState
) -> (state: RestoreSaveSchedulerState, request: RestoreSaveRequest?) {
    (
        RestoreSaveSchedulerState(nextGeneration: state.nextGeneration, pending: nil),
        state.pending
    )
}

public func cancelRestoreSave(in state: RestoreSaveSchedulerState) -> RestoreSaveSchedulerState {
    RestoreSaveSchedulerState(nextGeneration: state.nextGeneration, pending: nil)
}

@MainActor
public final class RestoreSaveScheduler {
    public typealias Save = (StoredWorld) throws -> Void
    public typealias Observe = (RestoreSaveEvent) -> Void

    private let urlPath: String
    private let debounceInterval: TimeInterval
    private let save: Save
    private let observe: Observe
    private var state = RestoreSaveSchedulerState.empty
    private var timer: Timer?
    private var timerGeneration: UInt64?

    public convenience init(
        manager: RestoreManager,
        debounceInterval: TimeInterval = 0.25,
        observe: @escaping Observe = { _ in }
    ) {
        self.init(
            urlPath: manager.url.path,
            debounceInterval: debounceInterval,
            save: { stored in
                try manager.save(stored)
            },
            observe: observe
        )
    }

    public init(
        urlPath: String,
        debounceInterval: TimeInterval,
        save: @escaping Save,
        observe: @escaping Observe = { _ in }
    ) {
        self.urlPath = urlPath
        self.debounceInterval = debounceInterval
        self.save = save
        self.observe = observe
    }

    public func scheduleSave(_ stored: StoredWorld, reason: String) {
        let scheduled = scheduleRestoreSave(stored, reason: reason, in: state)
        state = scheduled.state
        scheduleTimer(generation: scheduled.request.generation)
    }

    public func flushPending() {
        timer?.invalidate()
        timer = nil
        timerGeneration = nil
        let flushed = flushRestoreSave(in: state)
        state = flushed.state
        if let request = flushed.request {
            saveAndObserve(request)
        }
    }

    public func cancelPending() {
        timer?.invalidate()
        timer = nil
        timerGeneration = nil
        state = cancelRestoreSave(in: state)
    }

    private func scheduleTimer(generation: UInt64) {
        timer?.invalidate()
        let scheduled = Timer(timeInterval: debounceInterval, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.fireTimer(generation: generation)
            }
        }
        timer = scheduled
        timerGeneration = generation
        RunLoop.main.add(scheduled, forMode: .common)
    }

    private func fireTimer(generation: UInt64) {
        if timerGeneration == generation {
            timer?.invalidate()
            timer = nil
            timerGeneration = nil
        }
        let fired = fireRestoreSaveTimer(generation: generation, in: state)
        state = fired.state
        guard case .save(let request) = fired.decision else { return }
        saveAndObserve(request)
    }

    private func saveAndObserve(_ request: RestoreSaveRequest) {
        do {
            try save(request.stored)
            observe(restoreSaveSuccessEvent(for: request, urlPath: urlPath))
        } catch {
            observe(restoreSaveFailureEvent(for: request, urlPath: urlPath, message: String(describing: error)))
        }
    }
}

func restoreSaveSuccessEvent(for request: RestoreSaveRequest, urlPath: String) -> RestoreSaveEvent {
    .saved(RestoreSaveSuccess(
        generation: request.generation,
        reason: request.reason,
        urlPath: urlPath
    ))
}

func restoreSaveFailureEvent(for request: RestoreSaveRequest, urlPath: String, message: String) -> RestoreSaveEvent {
    .failed(RestoreSaveFailure(
        generation: request.generation,
        reason: request.reason,
        urlPath: urlPath,
        message: message
    ))
}

@MainActor
public final class RestorePersistence {
    private let manager: RestoreManager
    private let scheduler: RestoreSaveScheduler

    public var url: URL {
        manager.url
    }

    public init(
        manager: RestoreManager,
        debounceInterval: TimeInterval = 0.25,
        observe: @escaping RestoreSaveScheduler.Observe = { _ in }
    ) {
        self.manager = manager
        self.scheduler = RestoreSaveScheduler(
            manager: manager,
            debounceInterval: debounceInterval,
            observe: observe
        )
    }

    public func load() throws -> StoredWorld? {
        try manager.load()
    }

    public func scheduleSave(_ stored: StoredWorld, reason: String) {
        scheduler.scheduleSave(stored, reason: reason)
    }

    public func flushPending() {
        scheduler.flushPending()
    }

    public func cancelPending() {
        scheduler.cancelPending()
    }
}
