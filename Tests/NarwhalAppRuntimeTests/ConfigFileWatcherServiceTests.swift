import Foundation
import Testing
@testable import NarwhalAppRuntime

/// Integration tests: these use real FSEvents on a temporary directory.
@Suite("Config file watcher (integration)", .serialized)
@MainActor
struct ConfigFileWatcherServiceTests {
    @Test("Saving the target of a symlinked config triggers exactly one reload")
    func savingSymlinkTargetTriggersReload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realDirectory = root.appendingPathComponent("dotfiles", isDirectory: true)
        let linkDirectory = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        let realConfig = realDirectory.appendingPathComponent("init.lua")
        try "return {}".write(to: realConfig, atomically: true, encoding: .utf8)
        let linkedConfig = linkDirectory.appendingPathComponent("init.lua")
        try FileManager.default.createSymbolicLink(at: linkedConfig, withDestinationURL: realConfig)
        let reloads = ReloadCounter()
        let watcher = ConfigFileWatcherService(configURL: linkedConfig, reporter: reporter()) {
            reloads.count += 1
        }
        watcher.start()
        defer { watcher.stop() }
        // Let FSEvents deliver anything from creating the fixture, then count one save.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        reloads.count = 0

        try "return { border = { width = 3 } }".write(to: realConfig, atomically: true, encoding: .utf8)

        #expect(try await waitUntil { reloads.count > 0 })
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(reloads.count == 1)
    }

    @Test("An atomic save of a plain config in a symlinked temporary path triggers exactly one reload")
    func atomicSaveInSymlinkedPathTriggersReload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("init.lua")
        try "return {}".write(to: config, atomically: true, encoding: .utf8)
        let reloads = ReloadCounter()
        let watcher = ConfigFileWatcherService(configURL: config, reporter: reporter()) {
            reloads.count += 1
        }
        watcher.start()
        defer { watcher.stop() }
        // Let FSEvents deliver anything from creating the fixture, then count one save.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        reloads.count = 0

        try "return { hud = { enabled = false } }".write(to: config, atomically: true, encoding: .utf8)

        #expect(try await waitUntil { reloads.count > 0 })
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(reloads.count == 1)
    }

    private final class ReloadCounter {
        var count = 0
    }

    /// `FileManager.temporaryDirectory` lives under `/var`, itself a symlink to
    /// `/private/var`, which FSEvents always reports resolved.
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-config-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func reporter() -> StartupReporter {
        StartupReporter(logPath: "/tmp/narwhal-config-watcher-\(UUID().uuidString).log")
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
}
