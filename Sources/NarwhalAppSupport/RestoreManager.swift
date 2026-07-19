import Foundation
import NarwhalCore

public enum RestoreManagerError: Error, CustomStringConvertible, Equatable, Sendable {
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

public struct RestoreRecovery: Equatable, Sendable {
    public let primaryError: RestoreManagerError
    public let backupError: RestoreManagerError?
    public let quarantinedFilenames: [String]

    public init(
        primaryError: RestoreManagerError,
        backupError: RestoreManagerError?,
        quarantinedFilenames: [String]
    ) {
        self.primaryError = primaryError
        self.backupError = backupError
        self.quarantinedFilenames = quarantinedFilenames
    }
}

public enum RestoreLoadOutcome: Equatable, Sendable {
    case missing
    case loaded(StoredWorld)
    case recoveredFromBackup(StoredWorld, recovery: RestoreRecovery)
    case recoveredEmpty(RestoreRecovery)
    case incompatible(RestoreRecovery)
}

public struct RestoreManager: Sendable {
    public static let defaultURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("narwhal", isDirectory: true)
        .appendingPathComponent("state.json", isDirectory: false)

    public let url: URL

    public var backupURL: URL {
        url.appendingPathExtension("previous")
    }

    public init(url: URL = RestoreManager.defaultURL) {
        self.url = url
    }

    public func load() throws -> StoredWorld? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        return try loadStoredWorld(at: url)
    }

    public func loadRecovering(quarantineID: String = UUID().uuidString) throws -> RestoreLoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

        do {
            return .loaded(try loadStoredWorld(at: url))
        } catch let primaryError as RestoreManagerError {
            if case .unsupportedSchemaVersion = primaryError {
                return .incompatible(RestoreRecovery(
                    primaryError: primaryError,
                    backupError: nil,
                    quarantinedFilenames: []
                ))
            }
            let quarantinedPrimary = try quarantine(url, id: quarantineID)

            guard FileManager.default.fileExists(atPath: backupURL.path) else {
                return .recoveredEmpty(RestoreRecovery(
                    primaryError: primaryError,
                    backupError: nil,
                    quarantinedFilenames: [quarantinedPrimary.lastPathComponent]
                ))
            }

            do {
                let stored = try loadStoredWorld(at: backupURL)
                try encodeStoredWorldRestoreData(stored).write(to: url, options: [.atomic])
                try restrictPermissions(of: url)
                return .recoveredFromBackup(
                    stored,
                    recovery: RestoreRecovery(
                        primaryError: primaryError,
                        backupError: nil,
                        quarantinedFilenames: [quarantinedPrimary.lastPathComponent]
                    )
                )
            } catch let backupError as RestoreManagerError {
                if case .unsupportedSchemaVersion = backupError {
                    return .incompatible(RestoreRecovery(
                        primaryError: primaryError,
                        backupError: backupError,
                        quarantinedFilenames: [quarantinedPrimary.lastPathComponent]
                    ))
                }
                let quarantinedBackup = try quarantine(backupURL, id: quarantineID)
                return .recoveredEmpty(RestoreRecovery(
                    primaryError: primaryError,
                    backupError: backupError,
                    quarantinedFilenames: [
                        quarantinedPrimary.lastPathComponent,
                        quarantinedBackup.lastPathComponent
                    ]
                ))
            }
        }
    }

    public func save(_ stored: StoredWorld) throws {
        let current = try migrateStoredWorldToCurrent(stored).get()
        let validated = try validateCurrentStoredWorld(current).get()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )

        let encoded = try encodeStoredWorldRestoreData(validated)
        if FileManager.default.fileExists(atPath: url.path) {
            let currentData = try Data(contentsOf: url)
            switch decodeStoredWorldRestoreData(currentData) {
            case .success:
                try currentData.write(to: backupURL, options: [.atomic])
                try restrictPermissions(of: backupURL)
            case .failure(let error):
                throw error
            }
        }
        try encoded.write(to: url, options: [.atomic])
        try restrictPermissions(of: url)
    }

    private func loadStoredWorld(at fileURL: URL) throws -> StoredWorld {
        let data = try Data(contentsOf: fileURL)
        return try decodeStoredWorldRestoreData(data).get()
    }

    private func quarantine(_ fileURL: URL, id: String) throws -> URL {
        let destination = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(id)")
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }

    private func restrictPermissions(of fileURL: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

func decodeStoredWorldRestoreData(_ data: Data) -> Result<StoredWorld, RestoreManagerError> {
    let stored: StoredWorld
    do {
        stored = try JSONDecoder().decode(StoredWorld.self, from: data)
    } catch {
        return .failure(.decodeFailed(String(describing: error)))
    }

    switch migrateStoredWorldToCurrent(stored) {
    case .failure(let error):
        return .failure(error)
    case .success(let migrated):
        return validateCurrentStoredWorld(migrated)
    }
}

func migrateStoredWorldToCurrent(_ stored: StoredWorld) -> Result<StoredWorld, RestoreManagerError> {
    guard (1...StoredWorld.currentSchemaVersion).contains(stored.schemaVersion) else {
        return .failure(.unsupportedSchemaVersion(
            found: stored.schemaVersion,
            supported: StoredWorld.currentSchemaVersion
        ))
    }

    var migrated = stored
    while migrated.schemaVersion < StoredWorld.currentSchemaVersion {
        switch migrated.schemaVersion {
        case 1:
            migrated = StoredWorld(
                schemaVersion: 2,
                activeSpace: migrated.activeSpace,
                workspaces: migrated.workspaces,
                pendingRules: migrated.pendingRules
            )
        default:
            return .failure(.unsupportedSchemaVersion(
                found: migrated.schemaVersion,
                supported: StoredWorld.currentSchemaVersion
            ))
        }
    }
    return .success(migrated)
}

private func validateCurrentStoredWorld(_ stored: StoredWorld) -> Result<StoredWorld, RestoreManagerError> {
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
    public typealias Save = @Sendable (StoredWorld) async throws -> Void
    public typealias Observe = @MainActor @Sendable (RestoreSaveEvent) -> Void

    private let urlPath: String
    private let debounceInterval: TimeInterval
    private let save: Save
    private let observe: Observe
    private var state = RestoreSaveSchedulerState.empty
    private var timer: Timer?
    private var timerGeneration: UInt64?
    private var saveTail: Task<Void, Never>?
    private var saveTailGeneration: UInt64 = 0

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

    public func flushPending() async {
        timer?.invalidate()
        timer = nil
        timerGeneration = nil
        let flushed = flushRestoreSave(in: state)
        state = flushed.state
        if let request = flushed.request {
            enqueueSave(request)
        }
        await saveTail?.value
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
        enqueueSave(request)
    }

    private func enqueueSave(_ request: RestoreSaveRequest) {
        let previous = saveTail
        let save = self.save
        let observe = self.observe
        let urlPath = self.urlPath
        saveTailGeneration += 1
        let tailGeneration = saveTailGeneration
        let clearCompletedTail: @MainActor @Sendable (UInt64) -> Void = { [weak self] generation in
            guard self?.saveTailGeneration == generation else { return }
            self?.saveTail = nil
        }
        saveTail = Task.detached {
            await previous?.value
            let event: RestoreSaveEvent
            do {
                try await save(request.stored)
                event = restoreSaveSuccessEvent(for: request, urlPath: urlPath)
            } catch {
                event = restoreSaveFailureEvent(
                    for: request,
                    urlPath: urlPath,
                    message: String(describing: error)
                )
            }
            await observe(event)
            await clearCompletedTail(tailGeneration)
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
    private let restoreURL: URL
    private let store: RestoreFileStore
    private let scheduler: RestoreSaveScheduler

    public var url: URL {
        restoreURL
    }

    public init(
        manager: RestoreManager,
        debounceInterval: TimeInterval = 0.25,
        measureSave: @escaping @Sendable (Double) -> Void = { _ in },
        observe: @escaping RestoreSaveScheduler.Observe = { _ in }
    ) {
        self.restoreURL = manager.url
        let store = RestoreFileStore(manager: manager)
        self.store = store
        self.scheduler = RestoreSaveScheduler(
            urlPath: manager.url.path,
            debounceInterval: debounceInterval,
            save: { stored in
                let startedAt = ProcessInfo.processInfo.systemUptime
                defer {
                    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                    measureSave(max(0, elapsed) * 1_000)
                }
                try await store.save(stored)
            },
            observe: observe
        )
    }

    public func load() async throws -> StoredWorld? {
        try await store.load()
    }

    public func loadRecovering() async throws -> RestoreLoadOutcome {
        try await store.loadRecovering()
    }

    public func scheduleSave(_ stored: StoredWorld, reason: String) {
        scheduler.scheduleSave(stored, reason: reason)
    }

    public func flushPending() async {
        await scheduler.flushPending()
    }

    public func cancelPending() {
        scheduler.cancelPending()
    }
}

private actor RestoreFileStore {
    let manager: RestoreManager

    init(manager: RestoreManager) {
        self.manager = manager
    }

    func load() throws -> StoredWorld? {
        try manager.load()
    }

    func loadRecovering() throws -> RestoreLoadOutcome {
        try manager.loadRecovering()
    }

    func save(_ stored: StoredWorld) throws {
        try manager.save(stored)
    }
}
