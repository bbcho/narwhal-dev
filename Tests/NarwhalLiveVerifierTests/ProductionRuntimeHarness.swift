#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import Foundation
import NarwhalCore
import NarwhalIPC

struct RuntimeEvidenceBaseline {
    let manualResizeHandoffSamples: UInt64
    let layoutTransactionSamples: UInt64
    let droppedLogLineCount: UInt64
}

@MainActor
struct ProductionRuntimeHarness {
    let process: Process
    let temporaryRoot: URL
    let logURL: URL
    let ctlURL: URL
    let consoleHandle: FileHandle

    static func start(config: Config = .default) throws -> ProductionRuntimeHarness {
        guard !FileManager.default.fileExists(atPath: IPCDefaults.socketPath) else {
            throw RealAppWindowVerifierFailure("production verifier requires no existing Narwhal IPC socket")
        }

        let appURL = try builtProduct(named: "NarwhalApp")
        let ctlURL = try builtProduct(named: "NarwhalCtl")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-production-runtime-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let logDirectory = root.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        try DefaultConfigLua.render(config).write(
            to: configDirectory.appendingPathComponent("init.lua"),
            atomically: true,
            encoding: .utf8
        )
        let logURL = logDirectory.appendingPathComponent("narwhal.log")
        let consoleURL = logDirectory.appendingPathComponent("console.log")
        _ = FileManager.default.createFile(atPath: consoleURL.path, contents: nil)
        let consoleHandle = try FileHandle(forWritingTo: consoleURL)

        let process = Process()
        process.executableURL = appURL
        process.arguments = [
            "--config", configDirectory.appendingPathComponent("init.lua").path,
            "--restore-state", stateDirectory.appendingPathComponent("state.json").path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["NARWHAL_LOG_PATH"] = logURL.path
        process.environment = environment
        process.standardOutput = consoleHandle
        process.standardError = consoleHandle
        do {
            try process.run()
        } catch {
            try? consoleHandle.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return ProductionRuntimeHarness(
            process: process,
            temporaryRoot: root,
            logURL: logURL,
            ctlURL: ctlURL,
            consoleHandle: consoleHandle
        )
    }

    func waitUntilReady() async throws -> RuntimeDiagnostics {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            guard process.isRunning else {
                throw RealAppWindowVerifierFailure(
                    "production NarwhalApp exited during startup with status \(process.terminationStatus)"
                )
            }
            if FileManager.default.fileExists(atPath: IPCDefaults.socketPath),
               let status = try? diagnostics(),
               status.accessibilityTrusted,
               status.notificationFastPathActive,
               status.configHealthy,
               status.snapshotQuality == .complete {
                return status
            }
            await settleLiveVerifier(for: 0.1)
        }
        throw RealAppWindowVerifierFailure("production NarwhalApp did not become AX and IPC ready; log=\(logText)")
    }

    func send(_ command: IPCCommandDTO) throws {
        let reply = try IPCClient(ioTimeout: 5).send(command)
        guard case .ok = reply else {
            throw RealAppWindowVerifierFailure("production IPC command failed: \(reply)")
        }
    }

    func diagnostics() throws -> RuntimeDiagnostics {
        let reply = try IPCClient(ioTimeout: 5).send(.status)
        guard case .diagnostics(_, let value) = reply else {
            throw RealAppWindowVerifierFailure("production IPC status failed: \(reply)")
        }
        return value
    }

    func waitUntilIdle() async throws -> RuntimeDiagnostics {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let status = try diagnostics()
            if status.pendingGeometryEventCount == 0 { return status }
            await settleLiveVerifier(for: 0.04)
        }
        throw RealAppWindowVerifierFailure("production geometry queue did not become idle")
    }

    func captureEvidenceBaseline() throws -> RuntimeEvidenceBaseline {
        let status = try diagnostics()
        return RuntimeEvidenceBaseline(
            manualResizeHandoffSamples: sampleCount(.manualResizeHandoff, in: status),
            layoutTransactionSamples: sampleCount(.layoutTransaction, in: status),
            droppedLogLineCount: status.droppedLogLineCount
        )
    }

    func waitForManualResize(
        from baseline: RuntimeEvidenceBaseline,
        deadline interval: TimeInterval
    ) async throws -> RuntimeDiagnostics {
        let deadline = Date().addingTimeInterval(interval)
        var qualifying: RuntimeDiagnostics?
        while Date() < deadline {
            let status = try diagnostics()
            if status.pendingGeometryEventCount == 0,
               sampleCount(.manualResizeHandoff, in: status) == baseline.manualResizeHandoffSamples + 1,
               sampleCount(.layoutTransaction, in: status) == baseline.layoutTransactionSamples + 1 {
                qualifying = status
                break
            }
            await settleLiveVerifier(for: 0.02)
        }
        guard qualifying != nil else {
            throw RealAppWindowVerifierFailure("production manual resize did not complete exactly once before deadline")
        }
        await settleLiveVerifier(for: ExternalGeometryCoordinator.settleInterval * 2)
        let final = try diagnostics()
        guard final.pendingGeometryEventCount == 0,
              sampleCount(.manualResizeHandoff, in: final) == baseline.manualResizeHandoffSamples + 1,
              sampleCount(.layoutTransaction, in: final) == baseline.layoutTransactionSamples + 1,
              final.droppedLogLineCount == baseline.droppedLogLineCount
        else {
            throw RealAppWindowVerifierFailure("production manual resize emitted duplicate or dropped evidence")
        }
        return final
    }

    func stop() throws {
        if process.isRunning {
            try send(.quit)
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        guard !process.isRunning else {
            throw RealAppWindowVerifierFailure("production NarwhalApp did not exit after IPC quit")
        }
        try consoleHandle.close()
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    func stopBestEffort() {
        if process.isRunning {
            _ = try? IPCClient(ioTimeout: 1).send(.quit)
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if process.isRunning {
                process.terminate()
                let forcedDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < forcedDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
        }
        try? consoleHandle.close()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    var logText: String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    private static func builtProduct(named name: String) throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = packageRoot.appendingPathComponent(".build/debug/\(name)")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw RealAppWindowVerifierFailure("could not locate built product at \(candidate.path)")
        }
        return candidate
    }

    private func sampleCount(_ metric: RuntimeMetricKind, in diagnostics: RuntimeDiagnostics) -> UInt64 {
        diagnostics.latency.first(where: { $0.metric == metric })?.sampleCount ?? 0
    }
}

#endif
