import CoreGraphics
import Foundation
import Testing
import WinMgrCore
@testable import WinMgrAppSupport

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

        guard case .decodeFailed(let message) = error else {
            Issue.record("Expected decodeFailed, got \(error.description)")
            throw RestoreManagerTestError.unexpectedError
        }
        #expect(message.isEmpty == false)
        #expect(error.description == "restore JSON decode failed: \(message)")
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
        #expect(savedJSON.contains(#""schemaVersion" : 1"#))
        #expect(savedJSON.contains(#""displayFingerprint" : "main-display""#))
    }

    @Test("Scheduled saves debounce to the latest stored world")
    func scheduledSavesDebounceToLatestStoredWorld() async throws {
        let saves = RecordedRestoreSaves()
        let events = RecordedRestoreEvents()
        let scheduler = RestoreSaveScheduler(
            urlPath: "/tmp/winmgr-state.json",
            debounceNanoseconds: 20_000_000,
            save: { stored in
                try saves.save(stored)
            },
            observe: { event in
                events.record(event)
            }
        )
        let first = storedWorldFixture(title: "first")
        let second = storedWorldFixture(title: "second")

        await scheduler.scheduleSave(first, reason: "first")
        await scheduler.scheduleSave(second, reason: "second")

        try await waitUntil("latest debounced save") {
            saves.savedWorlds().count == 1
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(saves.savedWorlds() == [second])
        #expect(events.events() == [
            .saved(RestoreSaveSuccess(
                generation: 2,
                reason: "second",
                urlPath: "/tmp/winmgr-state.json"
            ))
        ])
    }

    @Test("Flush writes pending save immediately and cancels delayed write")
    func flushWritesPendingSaveImmediatelyAndCancelsDelayedWrite() async throws {
        let saves = RecordedRestoreSaves()
        let events = RecordedRestoreEvents()
        let scheduler = RestoreSaveScheduler(
            urlPath: "/tmp/winmgr-state.json",
            debounceNanoseconds: 50_000_000,
            save: { stored in
                try saves.save(stored)
            },
            observe: { event in
                events.record(event)
            }
        )
        let stored = storedWorldFixture(title: "flush")

        await scheduler.scheduleSave(stored, reason: "flush")
        await scheduler.flushPending()
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(saves.savedWorlds() == [stored])
        #expect(events.events() == [
            .saved(RestoreSaveSuccess(
                generation: 1,
                reason: "flush",
                urlPath: "/tmp/winmgr-state.json"
            ))
        ])
    }

    @Test("Failed save reports failure and next schedule can save")
    func failedSaveReportsFailureAndNextScheduleCanSave() async throws {
        let saves = RecordedRestoreSaves(failuresBeforeSuccess: 1)
        let events = RecordedRestoreEvents()
        let scheduler = RestoreSaveScheduler(
            urlPath: "/tmp/winmgr-state.json",
            debounceNanoseconds: 20_000_000,
            save: { stored in
                try saves.save(stored)
            },
            observe: { event in
                events.record(event)
            }
        )
        let failed = storedWorldFixture(title: "failed")
        let saved = storedWorldFixture(title: "saved")

        await scheduler.scheduleSave(failed, reason: "first")
        try await waitUntil("failed save event") {
            events.events().count == 1
        }
        await scheduler.scheduleSave(saved, reason: "second")
        try await waitUntil("successful retry save") {
            events.events().count == 2
        }

        #expect(saves.savedWorlds() == [saved])
        #expect(events.events() == [
            .failed(RestoreSaveFailure(
                generation: 1,
                reason: "first",
                urlPath: "/tmp/winmgr-state.json",
                message: "boom"
            )),
            .saved(RestoreSaveSuccess(
                generation: 2,
                reason: "second",
                urlPath: "/tmp/winmgr-state.json"
            ))
        ])
    }

    @Test("Cancel drops pending save without writing")
    func cancelDropsPendingSaveWithoutWriting() async throws {
        let saves = RecordedRestoreSaves()
        let events = RecordedRestoreEvents()
        let scheduler = RestoreSaveScheduler(
            urlPath: "/tmp/winmgr-state.json",
            debounceNanoseconds: 20_000_000,
            save: { stored in
                try saves.save(stored)
            },
            observe: { event in
                events.record(event)
            }
        )

        await scheduler.scheduleSave(storedWorldFixture(title: "cancel"), reason: "cancel")
        await scheduler.cancelPending()
        try await Task.sleep(nanoseconds: 50_000_000)

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
        .appendingPathComponent("winmgr-restore-manager-\(UUID().uuidString)", isDirectory: true)
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
        Issue.record("Expected RestoreManagerError")
        throw RestoreManagerTestError.unexpectedSuccess
    } catch let error as RestoreManagerError {
        return error
    }
}

private enum RestoreManagerTestError: Error {
    case unexpectedSuccess
    case unexpectedError
    case timeout
}

private final class RecordedRestoreSaves: @unchecked Sendable {
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

private final class RecordedRestoreEvents: @unchecked Sendable {
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

private func waitUntil(_ description: String, condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("Timed out waiting for \(description)")
    throw RestoreManagerTestError.timeout
}
