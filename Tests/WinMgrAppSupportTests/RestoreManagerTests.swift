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

    private func storedWorldFixture() -> StoredWorld {
        let ref = StoredWindowRef(
            bundleID: BundleID(raw: "com.example"),
            title: "Window",
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
}
