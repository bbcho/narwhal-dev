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

    @Test("Unsupported schema version loads as nil")
    func unsupportedSchemaVersionLoadsAsNil() throws {
        let paths = temporaryRestorePath()
        defer { removeTemporaryRestoreRoot(paths.root) }
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion + 1,
            activeSpace: nil,
            pendingRules: []
        )
        try writeStoredWorld(stored, to: paths.file)

        let loaded = try RestoreManager(url: paths.file).load()

        #expect(loaded == nil)
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
        #expect(try decodeStoredWorldRestoreData(try encodeStoredWorldRestoreData(unsupported)).get() == nil)
        switch decodeStoredWorldRestoreData(Data("not-json".utf8)) {
        case .failure(let error):
            #expect(error.description.hasPrefix("restore JSON decode failed:"))
        case .success(let value):
            #expect(Bool(false), "Expected decode failure, got \(String(describing: value))")
        }
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
    func schedulerFlushWritesLatestPendingSaveImmediately() {
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
        scheduler.flushPending()

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
    func schedulerFailedSaveReportsFailureAndLaterFlushCanSave() {
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
        scheduler.flushPending()
        scheduler.scheduleSave(saved, reason: "second")
        scheduler.flushPending()

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
    func schedulerCancelDropsPendingSaveWithoutWriting() {
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
        scheduler.flushPending()

        #expect(saves.savedWorlds() == [])
        #expect(events.events() == [])
    }

    private func storedWorldFixture(title: String = "Window") -> StoredWorld {
        let ref = StoredWindowRef(
            bundleID: BundleID(raw: "com.example"),
            title: title,
            role: "AXWindow",
            occurrence: 0,
            lastKnownFrame: CGRect(x: 10, y: 20, width: 300, height: 200)
        )
        return StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
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
