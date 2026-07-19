import CoreGraphics
import Foundation
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Restore persistence boundary")
struct RestoreManagerTests {
    @Test("Missing restore file loads as nil")
    func missingRestoreFileLoadsAsNil() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }

        let loaded = try RestoreManager(url: paths.file).load()

        #expect(loaded == nil)
    }

    @Test("Unsupported schema version fails without modifying the restore file")
    func unsupportedSchemaVersionFailsWithoutModifyingRestoreFile() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion + 1,
            activeSpace: nil,
            pendingRules: []
        )
        try writeStoredWorld(stored, to: paths.file)

        let original = try Data(contentsOf: paths.file)
        let error = try requireRestoreManagerError {
            try RestoreManager(url: paths.file).load()
        }

        #expect(error == .unsupportedSchemaVersion(
            found: StoredWorld.currentSchemaVersion + 1,
            supported: StoredWorld.currentSchemaVersion
        ))
        #expect(try Data(contentsOf: paths.file) == original)
    }

    @Test("Corrupt JSON throws decode failure")
    func corruptJSONThrowsDecodeFailure() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        try writeText("not-json", to: paths.file)

        let error = try requireRestoreManagerError {
            try RestoreManager(url: paths.file).load()
        }

        switch error {
        case .decodeFailed(let message):
            #expect(message.isEmpty == false)
            #expect(error.description == "restore JSON decode failed: \(message)")
        default:
            #expect(Bool(false), "Expected decodeFailed, got \(error.description)")
        }
    }

    @Test("Invalid stored world throws validation failure")
    func invalidStoredWorldThrowsValidationFailure() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        let invalidRef = StoredWindowRef(
            bundleID: BundleID(raw: "com.example"),
            title: "Bad",
            role: "AXWindow",
            occurrence: -1,
            lastKnownFrame: nil
        )
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: nil,
            pendingRules: [StoredPendingRule(window: invalidRef, action: .ignore)]
        )
        try writeStoredWorld(stored, to: paths.file)

        let error = try requireRestoreManagerError {
            try RestoreManager(url: paths.file).load()
        }

        #expect(error == .invalidStoredWorld("StoredWindowRef.occurrence must be non-negative"))
        #expect(error.description == "restore JSON invalid: StoredWindowRef.occurrence must be non-negative")
    }

    @Test("Save creates parent directory and load round-trips the stored world")
    func saveCreatesParentDirectoryAndLoadRoundTripsStoredWorld() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        let stored = storedWorldFixture()
        let manager = RestoreManager(url: paths.file)

        try manager.save(stored)

        #expect(FileManager.default.fileExists(atPath: paths.file.path))
        #expect(try manager.load() == stored)
        let savedJSON = try String(contentsOf: paths.file, encoding: .utf8)
        #expect(savedJSON.contains(#""schemaVersion" : \#(StoredWorld.currentSchemaVersion)"#))
        #expect(savedJSON.contains(#""displayFingerprint" : "main-display""#))
    }

    @Test("Restore JSON codec validates data without file I/O")
    func restoreJSONCodecValidatesDataWithoutFileIO() throws {
        let stored = storedWorldFixture()
        let encoded = try encodeStoredWorldRestoreData(stored)

        #expect(try decodeStoredWorldRestoreData(encoded).get() == stored)

        let unsupported = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion + 1,
            activeSpace: nil,
            pendingRules: []
        )
        #expect(decodeStoredWorldRestoreData(try encodeStoredWorldRestoreData(unsupported)) == .failure(
            .unsupportedSchemaVersion(
                found: StoredWorld.currentSchemaVersion + 1,
                supported: StoredWorld.currentSchemaVersion
            )
        ))
        switch decodeStoredWorldRestoreData(Data("not-json".utf8)) {
        case .failure(let error):
            #expect(error.description.hasPrefix("restore JSON decode failed:"))
        case .success(let value):
            #expect(Bool(false), "Expected decode failure, got \(String(describing: value))")
        }
    }

    @Test("Schema one restore migrates to the current schema before validation")
    func schemaOneRestoreMigratesToCurrentSchema() throws {
        let legacy = storedWorldFixture(title: "legacy", schemaVersion: 1)
        let current = storedWorldFixture(title: "legacy")

        #expect(migrateStoredWorldToCurrent(legacy) == .success(current))
        #expect(try decodeStoredWorldRestoreData(try encodeStoredWorldRestoreData(legacy)).get() == current)
        #expect(migrateStoredWorldToCurrent(current) == .success(current))
    }

    @Test("Released schema one fixture remains readable")
    func releasedSchemaOneFixtureRemainsReadable() throws {
        let fixture = try #require(Bundle.module.url(
            forResource: "v1-empty",
            withExtension: "json",
            subdirectory: "Fixtures/Restore"
        ))
        let decoded = try decodeStoredWorldRestoreData(Data(contentsOf: fixture)).get()

        #expect(decoded == StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: nil,
            workspaces: nil,
            pendingRules: []
        ))
    }

    @Test("Save retains the previous valid snapshot with private permissions")
    func saveRetainsPreviousValidSnapshot() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        let manager = RestoreManager(url: paths.file)
        let first = storedWorldFixture(title: "first")
        let second = storedWorldFixture(title: "second")

        try manager.save(first)
        #expect(FileManager.default.fileExists(atPath: manager.backupURL.path) == false)
        try manager.save(second)

        #expect(try manager.load() == second)
        let backupData = try Data(contentsOf: manager.backupURL)
        #expect(try decodeStoredWorldRestoreData(backupData).get() == first)
        #expect(posixPermissions(at: paths.file) == 0o600)
        #expect(posixPermissions(at: manager.backupURL) == 0o600)
        #expect(posixPermissions(at: paths.file.deletingLastPathComponent()) == 0o700)
    }

    @Test("Corrupt primary is quarantined and recovered from valid backup")
    func corruptPrimaryRecoversFromBackup() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        let manager = RestoreManager(url: paths.file)
        let backup = storedWorldFixture(title: "backup")

        try manager.save(backup)
        try manager.save(storedWorldFixture(title: "newest"))
        try writeText("not-json", to: paths.file)

        let outcome = try manager.loadRecovering(quarantineID: "test")

        guard case .recoveredFromBackup(let loaded, let recovery) = outcome else {
            Issue.record("Expected backup recovery, got \(outcome)")
            return
        }
        #expect(loaded == backup)
        #expect(recovery.backupError == nil)
        #expect(recovery.quarantinedFilenames == ["state.json.corrupt-test"])
        #expect(try manager.load() == backup)
        #expect(try String(contentsOf: quarantinedURL(named: "state.json.corrupt-test", paths: paths), encoding: .utf8) == "not-json")
    }

    @Test("Corrupt primary and backup are both quarantined before empty recovery")
    func corruptPrimaryAndBackupRecoverEmpty() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        let manager = RestoreManager(url: paths.file)
        try writeText("bad-primary", to: paths.file)
        try writeText("bad-backup", to: manager.backupURL)

        let outcome = try manager.loadRecovering(quarantineID: "both")

        guard case .recoveredEmpty(let recovery) = outcome else {
            Issue.record("Expected empty recovery, got \(outcome)")
            return
        }
        #expect(recovery.backupError != nil)
        #expect(recovery.quarantinedFilenames == [
            "state.json.corrupt-both",
            "state.json.previous.corrupt-both"
        ])
        #expect(FileManager.default.fileExists(atPath: paths.file.path) == false)
        #expect(FileManager.default.fileExists(atPath: manager.backupURL.path) == false)
        #expect(try String(contentsOf: quarantinedURL(named: "state.json.corrupt-both", paths: paths), encoding: .utf8) == "bad-primary")
        #expect(try String(contentsOf: quarantinedURL(named: "state.json.previous.corrupt-both", paths: paths), encoding: .utf8) == "bad-backup")
    }

    @Test("Future schema remains untouched for recovery by a newer app")
    func futureSchemaRemainsUntouched() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        let manager = RestoreManager(url: paths.file)
        let future = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion + 1,
            activeSpace: nil,
            pendingRules: []
        )
        try writeStoredWorld(future, to: paths.file)
        let original = try Data(contentsOf: paths.file)

        let outcome = try manager.loadRecovering(quarantineID: "future")

        guard case .incompatible(let recovery) = outcome else {
            Issue.record("Expected incompatible recovery, got \(outcome)")
            return
        }
        #expect(recovery.primaryError == .unsupportedSchemaVersion(
            found: StoredWorld.currentSchemaVersion + 1,
            supported: StoredWorld.currentSchemaVersion
        ))
        #expect(recovery.quarantinedFilenames == [])
        #expect(try Data(contentsOf: paths.file) == original)
    }

    @Test("Save refuses to overwrite invalid existing state")
    func saveRefusesToOverwriteInvalidExistingState() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        let manager = RestoreManager(url: paths.file)
        try writeText("not-json", to: paths.file)
        let original = try Data(contentsOf: paths.file)

        do {
            try manager.save(storedWorldFixture(title: "replacement"))
            Issue.record("Expected save to reject invalid existing state")
        } catch let error as RestoreManagerError {
            guard case .decodeFailed = error else {
                Issue.record("Expected decode failure, got \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: paths.file) == original)
        #expect(FileManager.default.fileExists(atPath: manager.backupURL.path) == false)
    }

    @Test("Future-schema backup remains untouched after corrupt primary")
    func futureSchemaBackupRemainsUntouched() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        let manager = RestoreManager(url: paths.file)
        let future = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion + 1,
            activeSpace: nil,
            pendingRules: []
        )
        try writeText("bad-primary", to: paths.file)
        try writeStoredWorld(future, to: manager.backupURL)
        let originalBackup = try Data(contentsOf: manager.backupURL)

        let outcome = try manager.loadRecovering(quarantineID: "future-backup")

        guard case .incompatible(let recovery) = outcome else {
            Issue.record("Expected incompatible recovery, got \(outcome)")
            return
        }
        #expect(recovery.backupError == .unsupportedSchemaVersion(
            found: StoredWorld.currentSchemaVersion + 1,
            supported: StoredWorld.currentSchemaVersion
        ))
        #expect(recovery.quarantinedFilenames == ["state.json.corrupt-future-backup"])
        #expect(try Data(contentsOf: manager.backupURL) == originalBackup)
    }

    @Test("Restore save events are pure request projections")
    func restoreSaveEventsArePureRequestProjections() {
        let request = RestoreSaveRequest(generation: 42, stored: storedWorldFixture(), reason: "manual")

        #expect(restoreSaveSuccessEvent(for: request, urlPath: "/tmp/state.json") == .saved(RestoreSaveSuccess(
            generation: 42,
            reason: "manual",
            urlPath: "/tmp/state.json"
        )))
        #expect(restoreSaveFailureEvent(
            for: request,
            urlPath: "/tmp/state.json",
            message: "boom"
        ) == .failed(RestoreSaveFailure(
            generation: 42,
            reason: "manual",
            urlPath: "/tmp/state.json",
            message: "boom"
        )))
    }

    @Test("Restore save scheduling keeps latest pending request")
    func restoreSaveSchedulingKeepsLatestPendingRequest() {
        let first = storedWorldFixture(title: "first")
        let second = storedWorldFixture(title: "second")

        let firstSchedule = scheduleRestoreSave(first, reason: "first", in: .empty)
        let secondSchedule = scheduleRestoreSave(second, reason: "second", in: firstSchedule.state)

        #expect(firstSchedule.request == RestoreSaveRequest(generation: 1, stored: first, reason: "first"))
        #expect(secondSchedule.request == RestoreSaveRequest(generation: 2, stored: second, reason: "second"))
        #expect(secondSchedule.state == RestoreSaveSchedulerState(
            nextGeneration: 3,
            pending: secondSchedule.request
        ))
    }

    @Test("Restore save timer ignores stale generation and saves current generation")
    func restoreSaveTimerIgnoresStaleGenerationAndSavesCurrentGeneration() {
        let first = storedWorldFixture(title: "first")
        let second = storedWorldFixture(title: "second")
        let firstSchedule = scheduleRestoreSave(first, reason: "first", in: .empty)
        let secondSchedule = scheduleRestoreSave(second, reason: "second", in: firstSchedule.state)

        let staleFire = fireRestoreSaveTimer(generation: firstSchedule.request.generation, in: secondSchedule.state)
        let currentFire = fireRestoreSaveTimer(generation: secondSchedule.request.generation, in: staleFire.state)

        #expect(staleFire.state == secondSchedule.state)
        #expect(staleFire.decision == .stale(pending: secondSchedule.request))
        #expect(currentFire.state == RestoreSaveSchedulerState(nextGeneration: 3, pending: nil))
        #expect(currentFire.decision == .save(secondSchedule.request))
    }

    @Test("Restore save flush returns pending request once")
    func restoreSaveFlushReturnsPendingRequestOnce() {
        let stored = storedWorldFixture(title: "flush")
        let scheduled = scheduleRestoreSave(stored, reason: "flush", in: .empty)

        let firstFlush = flushRestoreSave(in: scheduled.state)
        let secondFlush = flushRestoreSave(in: firstFlush.state)

        #expect(firstFlush.request == scheduled.request)
        #expect(firstFlush.state == RestoreSaveSchedulerState(nextGeneration: 2, pending: nil))
        #expect(secondFlush.request == nil)
        #expect(secondFlush.state == RestoreSaveSchedulerState(nextGeneration: 2, pending: nil))
    }

    @Test("Restore save cancellation clears pending request")
    func restoreSaveCancellationClearsPendingRequest() {
        let scheduled = scheduleRestoreSave(storedWorldFixture(title: "cancel"), reason: "cancel", in: .empty)

        let canceled = cancelRestoreSave(in: scheduled.state)
        let fired = fireRestoreSaveTimer(generation: scheduled.request.generation, in: canceled)

        #expect(canceled == RestoreSaveSchedulerState(nextGeneration: 2, pending: nil))
        #expect(fired.state == canceled)
        #expect(fired.decision == .idle)
    }

    @Test("Scheduler flush writes latest pending save immediately")
    @MainActor
    func schedulerFlushWritesLatestPendingSaveImmediately() async {
        let saves = RecordedRestoreSaves()
        let events = RecordedRestoreEvents()
        let scheduler = RestoreSaveScheduler(
            urlPath: "/tmp/narwhal-state.json",
            debounceInterval: 60.0,
            save: { stored in
                try saves.save(stored)
            },
            observe: { event in
                events.record(event)
            }
        )
        let first = storedWorldFixture(title: "first")
        let second = storedWorldFixture(title: "second")

        scheduler.scheduleSave(first, reason: "first")
        scheduler.scheduleSave(second, reason: "second")
        await scheduler.flushPending()

        #expect(saves.savedWorlds() == [second])
        #expect(events.events() == [
            .saved(RestoreSaveSuccess(
                generation: 2,
                reason: "second",
                urlPath: "/tmp/narwhal-state.json"
            ))
        ])
    }

    @Test("Scheduler failed save reports failure and later flush can save")
    @MainActor
    func schedulerFailedSaveReportsFailureAndLaterFlushCanSave() async {
        let saves = RecordedRestoreSaves(failuresBeforeSuccess: 1)
        let events = RecordedRestoreEvents()
        let scheduler = RestoreSaveScheduler(
            urlPath: "/tmp/narwhal-state.json",
            debounceInterval: 60.0,
            save: { stored in
                try saves.save(stored)
            },
            observe: { event in
                events.record(event)
            }
        )
        let failed = storedWorldFixture(title: "failed")
        let saved = storedWorldFixture(title: "saved")

        scheduler.scheduleSave(failed, reason: "first")
        await scheduler.flushPending()
        scheduler.scheduleSave(saved, reason: "second")
        await scheduler.flushPending()

        #expect(saves.savedWorlds() == [saved])
        #expect(events.events() == [
            .failed(RestoreSaveFailure(
                generation: 1,
                reason: "first",
                urlPath: "/tmp/narwhal-state.json",
                message: "boom"
            )),
            .saved(RestoreSaveSuccess(
                generation: 2,
                reason: "second",
                urlPath: "/tmp/narwhal-state.json"
            ))
        ])
    }

    @Test("Scheduler cancel drops pending save without writing")
    @MainActor
    func schedulerCancelDropsPendingSaveWithoutWriting() async {
        let saves = RecordedRestoreSaves()
        let events = RecordedRestoreEvents()
        let scheduler = RestoreSaveScheduler(
            urlPath: "/tmp/narwhal-state.json",
            debounceInterval: 60.0,
            save: { stored in
                try saves.save(stored)
            },
            observe: { event in
                events.record(event)
            }
        )

        scheduler.scheduleSave(storedWorldFixture(title: "cancel"), reason: "cancel")
        scheduler.cancelPending()
        await scheduler.flushPending()

        #expect(saves.savedWorlds() == [])
        #expect(events.events() == [])
    }

    @Test("Scheduler serializes a save queued while the previous save is in flight")
    @MainActor
    func schedulerSerializesInflightSaves() async {
        let first = storedWorldFixture(title: "first")
        let second = storedWorldFixture(title: "second")
        let probe = OrderedAsyncRestoreSaves(blockedWorld: first)
        let scheduler = RestoreSaveScheduler(
            urlPath: "/tmp/narwhal-state.json",
            debounceInterval: 60.0,
            save: { stored in await probe.save(stored) }
        )

        scheduler.scheduleSave(first, reason: "first")
        let firstFlush = Task { @MainActor in
            await scheduler.flushPending()
        }
        while await probe.startedCount() == 0 {
            await Task.yield()
        }

        scheduler.scheduleSave(second, reason: "second")
        let secondFlush = Task { @MainActor in
            await scheduler.flushPending()
        }
        await Task.yield()

        #expect(await probe.startedWorlds() == [first])
        await probe.releaseBlockedSave()
        await firstFlush.value
        await secondFlush.value
        #expect(await probe.startedWorlds() == [first, second])
        #expect(await probe.completedWorlds() == [first, second])
    }

    @Test("Restore persistence flush awaits the filesystem actor and reports timing")
    @MainActor
    func persistenceFlushAwaitsFilesystemActor() async throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        let durations = RecordedRestoreDurations()
        let persistence = RestorePersistence(
            manager: RestoreManager(url: paths.file),
            debounceInterval: 60.0,
            measureSave: { durations.record($0) }
        )
        let stored = storedWorldFixture(title: "background")

        persistence.scheduleSave(stored, reason: "test")
        await persistence.flushPending()

        #expect(try await persistence.load() == stored)
        #expect(durations.values().count == 1)
        #expect(durations.values().allSatisfy { $0 >= 0 })
    }

    private func storedWorldFixture(
        title: String = "Window",
        schemaVersion: Int = StoredWorld.currentSchemaVersion
    ) -> StoredWorld {
        let ref = StoredWindowRef(
            bundleID: BundleID(raw: "com.example"),
            title: title,
            role: "AXWindow",
            occurrence: 0,
            lastKnownFrame: CGRect(x: 10, y: 20, width: 300, height: 200)
        )
        return StoredWorld(
            schemaVersion: schemaVersion,
            activeSpace: StoredSpace(
                layouts: [
                    StoredDisplayLayout(
                        displaySlot: 0,
                        displayFingerprint: "main-display",
                        tree: .leaf(ref),
                        floating: [ref]
                    )
                ],
                focused: ref
            ),
            pendingRules: [StoredPendingRule(window: ref, action: .pinToDisplay(displaySlot: 0))]
        )
    }
}

private func quarantinedURL(
    named filename: String,
    paths: (root: URL, file: URL)
) -> URL {
    paths.file.deletingLastPathComponent().appendingPathComponent(filename)
}

private func posixPermissions(at url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue
}

private func temporaryRestorePath() -> (root: URL, file: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("narwhal-restore-manager-\(UUID().uuidString)", isDirectory: true)
    let file = root
        .appendingPathComponent("nested", isDirectory: true)
        .appendingPathComponent("state.json", isDirectory: false)
    return (root, file)
}

private func writeStoredWorld(_ stored: StoredWorld, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONEncoder().encode(stored).write(to: url)
}

private func writeText(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url)
}

private func removeTemporaryRestoreRoot(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func requireRestoreManagerError(
    _ operation: () throws -> StoredWorld?
) throws -> RestoreManagerError {
    do {
        _ = try operation()
        throw RestoreManagerTestError.unexpectedSuccess
    } catch let error as RestoreManagerError {
        return error
    }
}

private enum RestoreManagerTestError: Error {
    case unexpectedSuccess
}

private final class RecordedRestoreSaves {
    private let lock = NSLock()
    private var failuresBeforeSuccess: Int
    private var saved: [StoredWorld] = []

    init(failuresBeforeSuccess: Int = 0) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func save(_ stored: StoredWorld) throws {
        lock.lock()
        defer { lock.unlock() }
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw FakeRestoreSaveError.boom
        }
        saved.append(stored)
    }

    func savedWorlds() -> [StoredWorld] {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }
}

private actor OrderedAsyncRestoreSaves {
    private let blockedWorld: StoredWorld
    private var started: [StoredWorld] = []
    private var completed: [StoredWorld] = []
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(blockedWorld: StoredWorld) {
        self.blockedWorld = blockedWorld
    }

    func save(_ stored: StoredWorld) async {
        started.append(stored)
        if stored == blockedWorld {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        completed.append(stored)
    }

    func startedCount() -> Int {
        started.count
    }

    func startedWorlds() -> [StoredWorld] {
        started
    }

    func completedWorlds() -> [StoredWorld] {
        completed
    }

    func releaseBlockedSave() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private final class RecordedRestoreDurations: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Double] = []

    func record(_ duration: Double) {
        lock.lock()
        durations.append(duration)
        lock.unlock()
    }

    func values() -> [Double] {
        lock.lock()
        let snapshot = durations
        lock.unlock()
        return snapshot
    }
}

private final class RecordedRestoreEvents {
    private let lock = NSLock()
    private var recorded: [RestoreSaveEvent] = []

    func record(_ event: RestoreSaveEvent) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(event)
    }

    func events() -> [RestoreSaveEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private enum FakeRestoreSaveError: Error, CustomStringConvertible {
    case boom

    var description: String {
        "boom"
    }
}
