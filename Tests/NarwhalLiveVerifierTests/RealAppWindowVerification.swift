#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import CoreGraphics
import Darwin
import Foundation
import NarwhalAppSupport
import NarwhalCore
import NarwhalIPC
import Testing

@MainActor
@Suite(
    "Real app window verifiers",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["NARWHAL_RUN_REAL_APP_VERIFIERS"] == "1",
        "Set NARWHAL_RUN_REAL_APP_VERIFIERS=1 to move and restore real app windows."
    )
)
struct RealAppWindowVerificationTests {
    @Test("Firefox accepts real AX frame writes")
    func firefoxAcceptsRealAXFrameWrites() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifyFirefox())
    }

    @Test("Chrome accepts real AX frame writes")
    func chromeAcceptsRealAXFrameWrites() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifyChrome())
    }

    @Test("System Settings accepts real AX frame writes")
    func systemSettingsAcceptsRealAXFrameWrites() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifySystemSettings())
    }

    @Test("Real apps complete Narwhal command workflows")
    func realAppsCompleteNarwhalCommandWorkflows() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifyRealAppCommandWorkflows())
    }

    @Test("Production runtime moves real Terminal windows and owns current borders")
    func productionRuntimeMovesRealWindowsAndBorders() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifyProductionRuntimeIPCWorkflow())
    }

    @Test("Chrome and Firefox complete real manual tile resize")
    func chromeAndFirefoxCompleteRealManualTileResize() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifyChromeFirefoxManualTileResize())
    }

    @Test("Production 2-by-2 manual resize preserves the opposite row")
    func productionTwoByTwoManualResize() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await ProductionManualResizeVerification.verifyTwoByTwoTerminalResize())
    }

    @Test("Real Terminal moves to an adjacent Space and back")
    func realTerminalMovesAcrossSpaces() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealTerminalSpaceMoveVerification.verifyRoundTrip())
    }

    @Test("Three Firefox windows stack vertically")
    func threeFirefoxWindowsStackVertically() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifyThreeFirefoxVerticalStack())
    }

    @Test("Three Chrome windows stack vertically")
    func threeChromeWindowsStackVertically() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifyThreeChromeVerticalStack())
    }

    @Test("Four through eight Terminal windows tile and run mixed push sequences")
    func fourThroughEightTerminalWindowsTileInBothAxes() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifyTerminalTileMatrix())
    }

    @Test("Outlook side transfers keep equal halves and expand Terminal")
    func outlookSideTransfersKeepEqualHalvesAndExpandTerminal() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifyOutlookTerminalSideTransfer())
    }

    private func expectPassed(_ result: (passed: Bool, message: String)) throws {
        guard result.passed else {
            throw RealAppWindowVerifierFailure(result.message)
        }
    }
}

@MainActor
enum RealAppWindowVerification {
    private static let systemSettingsStableAXWidth: CGFloat = 724
    private static let firefoxManualStagingMinimumHeight: CGFloat = 640
    private static let manualResizeShrinkReserve: CGFloat = 120
    private static let manualResizeShrinkSafety: CGFloat = 8
    private static let realAppFrameWriteTolerance: CGFloat = 6
    private static let browserResizeReserveDelta = 0.18
    private static let coordinatedResizeDeadline: TimeInterval = 0.8
    private static let outlookStageObservationDuration: TimeInterval = 1.0
    private static let terminalPushSequencesByCount: [Int: [String]] = [
        4: ["HLHL", "KJKJ", "JKKL", "JKKH", "HLLJ", "HLLK"],
        5: [
            "JKJJL", "HLHHL", "HLHHH", "JKKKK",
            "LHLLH", "KJKKH", "LHLLL", "KJJJJ",
            "HLHHJ", "LHLLK", "JKKKL", "JKKKH",
            "HLLLJ", "HLLLK"
        ],
        6: ["HLHLHL", "KJKJKJ", "JKKKKL", "JKKKKH", "HLLLLJ", "HLLLLK"],
        7: ["JKKKKKL", "HLLLLLJ"],
        8: ["JKKKKKKH", "HLLLLLLK"]
    ]

    static func verifyFirefox() async -> (passed: Bool, message: String) {
        await verifyApp(firefoxSpec())
    }

    static func verifyChrome() async -> (passed: Bool, message: String) {
        await verifyApp(chromeSpec())
    }

    static func verifySystemSettings() async -> (passed: Bool, message: String) {
        await verifyApp(systemSettingsSpec())
    }

    static func verifyRealAppCommandWorkflows() async -> (passed: Bool, message: String) {
        do {
            try waitForUnlockedSession()
            let displays = DisplayClient().currentDisplays()
            guard let primary = displays.values.sorted(by: { $0.slot < $1.slot }).first else {
                throw RealAppWindowVerifierFailure("no displays available")
            }
            guard primary.visibleFrame.width >= 900 && primary.visibleFrame.height >= 620 else {
                throw RealAppWindowVerifierFailure("real app command workflow verification requires a display at least 900x620")
            }
            return (true, "real app command workflows passed: \(try await verifyRealCommandWorkflows(displays: displays))")
        } catch let error as RealAppWindowVerifierFailure {
            return (false, error.message)
        } catch {
            return (false, "real app command workflow verification failed: \(String(describing: error))")
        }
    }

    static func verifyChromeFirefoxManualTileResize() async -> (passed: Bool, message: String) {
        let axClient = AXClient(processID: -1, settleStrategy: .servicingRunLoop)
        var originals: [RealAppOriginal] = []
        var runtime: ProductionRuntimeHarness?
        do {
            try waitForUnlockedSession()
            let displays = DisplayClient().currentDisplays()
            guard displays.values.contains(where: { $0.visibleFrame.width >= 900 && $0.visibleFrame.height >= 620 }) else {
                throw RealAppWindowVerifierFailure("manual browser resize verification requires a display at least 900x620")
            }
            let targetDisplay = try productionManualResizeDisplay(displays)

            for spec in [chromeSpec(), firefoxSpec(), terminalSpec()] {
                originals.append(try await launchTrackedWindow(
                    spec: spec,
                    using: axClient,
                    requiringNewWindow: true,
                    token: "manual"
                ))
            }

            try await stageProductionManualResizeWindows(
                originals,
                on: targetDisplay,
                using: axClient
            )

            let config = Config(
                keymap: Config.default.keymap,
                rules: Config.default.rules,
                zones: Config.default.zones,
                gaps: Gaps(inner: 8, outer: Config.default.gaps.outer),
                border: Config.default.border,
                hud: Config.default.hud,
                dragModifier: Config.default.dragModifier,
                managedRules: Config.default.managedRules
            )
            let activeRuntime = try ProductionRuntimeHarness.start(config: config)
            runtime = activeRuntime
            _ = try await activeRuntime.waitUntilReady()

            let summary = try await verifyChromeFirefoxManualResizeWorkflow(
                originals,
                targetDisplay: targetDisplay,
                axClient: axClient,
                runtime: activeRuntime,
                innerGap: config.gaps.inner
            )

            try activeRuntime.stop()
            runtime = nil
            try await cleanupApps(originals, using: axClient)
            originals.removeAll()
            return (true, summary)
        } catch let error as RealAppWindowVerifierFailure {
            runtime?.stopBestEffort()
            await cleanupAppsBestEffort(originals, using: axClient, context: "REAL APP MANUAL RESIZE VERIFY")
            return (false, error.message)
        } catch {
            runtime?.stopBestEffort()
            await cleanupAppsBestEffort(originals, using: axClient, context: "REAL APP MANUAL RESIZE VERIFY")
            return (false, "manual browser resize verification failed: \(String(describing: error))")
        }
    }

    static func verifyThreeFirefoxVerticalStack() async -> (passed: Bool, message: String) {
        await verifyThreeWindowVerticalStack(spec: firefoxSpec(), label: "Firefox")
    }

    static func verifyThreeChromeVerticalStack() async -> (passed: Bool, message: String) {
        await verifyThreeWindowVerticalStack(spec: chromeSpec(), label: "Google Chrome")
    }

    static func verifyTerminalTileMatrix() async -> (passed: Bool, message: String) {
        let axClient = AXClient(processID: -1, settleStrategy: .servicingRunLoop)
        let overlay = Overlay(border: Config.default.border, hud: Config.default.hud)
        let axisConfig = Config(
            keymap: Config.default.keymap,
            rules: Config.default.rules,
            zones: Config.default.zones,
            gaps: Gaps(inner: 8, outer: Config.default.gaps.outer),
            border: Config.default.border,
            hud: Config.default.hud,
            dragModifier: Config.default.dragModifier,
            managedRules: Config.default.managedRules
        )
        let sequenceFilter = ProcessInfo.processInfo.environment["NARWHAL_TERMINAL_SEQUENCE_FILTER"]
        let matrixCounts: [Int]
        if let sequenceFilter {
            matrixCounts = terminalPushSequencesByCount.keys.filter {
                terminalPushSequencesByCount[$0]?.contains(sequenceFilter) == true
            }.sorted()
        } else {
            matrixCounts = Array(4...8)
        }
        defer { overlay.stop() }
        var originals: [RealAppOriginal] = []
        do {
            try waitForUnlockedSession()
            await activateLiveVerifierApplication()
            let displays = DisplayClient().currentDisplays()
            let targetDisplay = try manualResizeVerificationDisplay(displays)
            let minimum = terminalSpec().minimumWindowSize
            guard let maximumCount = matrixCounts.max() else {
                throw RealAppWindowVerifierFailure(
                    "Terminal sequence filter did not match a verifier case: \(sequenceFilter ?? "")"
                )
            }
            guard targetDisplay.visibleFrame.width / CGFloat(maximumCount) >= minimum.width,
                  targetDisplay.visibleFrame.height / CGFloat(maximumCount) >= minimum.height
            else {
                throw RealAppWindowVerifierFailure(
                    "Terminal \(maximumCount)-tile matrix requires at least "
                        + "\(minimum.width * CGFloat(maximumCount))x"
                        + "\(minimum.height * CGFloat(maximumCount)) visible points"
                )
            }

            var selectedIDs = Set<WindowID>()
            for count in matrixCounts {
                while originals.count < count {
                    let index = originals.count + 1
                    let original = try await launchTrackedWindow(
                        spec: terminalSpec(),
                        using: axClient,
                        requiringNewWindow: true,
                        excluding: selectedIDs,
                        token: "matrix-\(index)"
                    )
                    selectedIDs.insert(original.metadata.id)
                    originals.append(original)
                }

                if sequenceFilter == nil {
                    for axis in Axis.allCases {
                        _ = try await applyRealAxisLayout(
                            originals,
                            axis: axis,
                            label: "Terminal \(count)-tile \(axis.rawValue)",
                            targetDisplay: targetDisplay,
                            axClient: axClient,
                            displays: displays,
                            config: axisConfig
                        )
                        _ = try renderTerminalBorders(
                            originals,
                            using: axClient,
                            overlay: overlay
                        )
                        try await raiseForWindowServerVerification(
                            originals,
                            using: axClient,
                            context: "Terminal \(count)-tile \(axis.rawValue) borders"
                        )
                        try renderAndVerifyTerminalBorders(
                            originals,
                            on: targetDisplay,
                            using: axClient,
                            overlay: overlay,
                            context: "Terminal \(count)-tile \(axis.rawValue)"
                        )
                        report("REAL TILE MATRIX: \(count) Terminal windows tiled \(axis.rawValue)")
                        await settleLiveVerifier(for: 0.35)
                    }
                }

                let sequences = (terminalPushSequencesByCount[count] ?? []).filter {
                    sequenceFilter == nil || $0 == sequenceFilter
                }
                for sequence in sequences {
                    try await verifyTerminalPushSequence(
                        sequence,
                        originals: originals,
                        targetDisplay: targetDisplay,
                        axClient: axClient,
                        displays: displays,
                        overlay: overlay
                    )
                }
            }

            try await cleanupApps(originals, using: axClient)
            originals.removeAll()
            let summary = sequenceFilter.map {
                "real Terminal push sequence \($0) passed"
            } ?? "real Terminal 4-8 tile and mixed push-sequence matrix passed"
            return (true, summary)
        } catch let error as RealAppWindowVerifierFailure {
            await cleanupAppsBestEffort(originals, using: axClient, context: "REAL TERMINAL TILE MATRIX VERIFY")
            return (false, error.message)
        } catch {
            await cleanupAppsBestEffort(originals, using: axClient, context: "REAL TERMINAL TILE MATRIX VERIFY")
            return (false, "Terminal tile matrix verification failed: \(String(describing: error))")
        }
    }

    static func verifyProductionRuntimeIPCWorkflow() async -> (passed: Bool, message: String) {
        let axClient = AXClient(processID: -1, settleStrategy: .servicingRunLoop)
        var originals: [RealAppOriginal] = []
        var runtime: ProductionRuntime?
        do {
            try waitForUnlockedSession()
            guard !FileManager.default.fileExists(atPath: IPCDefaults.socketPath) else {
                throw RealAppWindowVerifierFailure(
                    "production runtime verifier requires no existing Narwhal IPC socket"
                )
            }

            let displays = DisplayClient().currentDisplays()
            let targetDisplay = try manualResizeVerificationDisplay(displays)
            var selectedIDs = Set<WindowID>()
            for index in 1...3 {
                let original = try await launchTrackedWindow(
                    spec: terminalSpec(),
                    using: axClient,
                    requiringNewWindow: true,
                    excluding: selectedIDs,
                    token: "production-runtime-\(index)"
                )
                selectedIDs.insert(original.metadata.id)
                originals.append(original)
            }
            try await stageTerminalPushSequenceWindows(
                originals,
                on: targetDisplay,
                using: axClient
            )

            let activeRuntime = try startProductionRuntime()
            runtime = activeRuntime
            try await waitForProductionRuntime(activeRuntime)
            await settleLiveVerifier(for: 0.8)

            try sendProductionCommand(.push(windowID: originals[0].metadata.id, direction: .left))
            try sendProductionCommand(.push(windowID: originals[1].metadata.id, direction: .right))
            try sendProductionCommand(.push(windowID: originals[2].metadata.id, direction: .left))
            await settleLiveVerifier(for: 0.25)

            let beforeTransfer = try productionTerminalFrames(originals, using: axClient)
            try requireProductionSideTransferLayout(
                frames: beforeTransfer,
                fullHeightWindow: originals[1].metadata.id,
                stackedWindows: [originals[0].metadata.id, originals[2].metadata.id],
                fullHeightSide: .right,
                display: targetDisplay,
                context: "production runtime before side transfer"
            )
            try requirePlannedRealFramesVisible(
                originals,
                plannedFrames: beforeTransfer,
                using: axClient,
                context: "production runtime before side transfer"
            )
            try requireProductionBorders(
                frames: beforeTransfer,
                ownerPID: activeRuntime.process.processIdentifier,
                display: targetDisplay,
                context: "production runtime before side transfer"
            )

            let leftWindowID = originals[0].metadata.id
            guard let oldLeftWindowFrame = beforeTransfer[leftWindowID] else {
                throw RealAppWindowVerifierFailure(
                    "production runtime omitted the left Terminal before side transfer"
                )
            }
            let oldLeftBorderFrame = productionBorderFrame(
                forAXFrame: oldLeftWindowFrame,
                on: targetDisplay
            )
            try runProductionPushAndCheckBorderClearing(
                executable: activeRuntime.ctlURL,
                windowID: originals[2].metadata.id,
                direction: .right,
                movedWindowID: leftWindowID,
                oldWindowFrame: oldLeftWindowFrame,
                oldBorderFrame: oldLeftBorderFrame,
                ownerPID: activeRuntime.process.processIdentifier,
                axClient: axClient
            )
            await settleLiveVerifier(for: 0.25)

            let afterTransfer = try productionTerminalFrames(originals, using: axClient)
            try requireProductionSideTransferLayout(
                frames: afterTransfer,
                fullHeightWindow: originals[0].metadata.id,
                stackedWindows: [originals[1].metadata.id, originals[2].metadata.id],
                fullHeightSide: .left,
                display: targetDisplay,
                context: "production runtime after side transfer"
            )
            try requirePlannedRealFramesVisible(
                originals,
                plannedFrames: afterTransfer,
                using: axClient,
                context: "production runtime after side transfer"
            )
            try requireProductionBorders(
                frames: afterTransfer,
                ownerPID: activeRuntime.process.processIdentifier,
                display: targetDisplay,
                context: "production runtime after side transfer"
            )

            try await cleanupApps(originals, using: axClient)
            originals.removeAll()
            try stopProductionRuntime(activeRuntime)
            runtime = nil
            return (
                true,
                "production AppDelegate and IPC side transfer passed with real AX, WindowServer, and border frames"
            )
        } catch let error as RealAppWindowVerifierFailure {
            await cleanupAppsBestEffort(originals, using: axClient, context: "PRODUCTION RUNTIME VERIFY")
            if let runtime {
                stopProductionRuntimeBestEffort(runtime)
            }
            return (false, error.message)
        } catch {
            await cleanupAppsBestEffort(originals, using: axClient, context: "PRODUCTION RUNTIME VERIFY")
            if let runtime {
                stopProductionRuntimeBestEffort(runtime)
            }
            return (false, "production runtime verification failed: \(String(describing: error))")
        }
    }

    static func verifyOutlookTerminalSideTransfer() async -> (passed: Bool, message: String) {
        let axClient = AXClient(processID: -1, settleStrategy: .servicingRunLoop)
        var originals: [RealAppOriginal] = []
        do {
            try waitForUnlockedSession()
            let displays = DisplayClient().currentDisplays()
            let targetDisplay = try manualResizeVerificationDisplay(displays)

            let leftTerminal = try await launchTrackedWindow(
                spec: terminalSpec(),
                using: axClient,
                requiringNewWindow: true,
                token: "outlook-left"
            )
            originals.append(leftTerminal)

            let rightTerminal = try await launchTrackedWindow(
                spec: terminalSpec(),
                using: axClient,
                requiringNewWindow: true,
                excluding: [leftTerminal.metadata.id],
                token: "outlook-right"
            )
            originals.append(rightTerminal)

            let outlook = try await launchTrackedWindow(
                spec: outlookSpec(),
                using: axClient,
                requiringNewWindow: false,
                token: "side-transfer"
            )
            originals.append(outlook)

            try await stageOutlookSideTransferWindows(
                leftTerminal: leftTerminal,
                rightTerminal: rightTerminal,
                outlook: outlook,
                on: targetDisplay,
                using: axClient
            )
            let summary = try await verifyOutlookSideTransferWorkflow(
                leftTerminal: leftTerminal,
                rightTerminal: rightTerminal,
                outlook: outlook,
                targetDisplay: targetDisplay,
                axClient: axClient,
                displays: displays
            )

            try await cleanupApps(originals, using: axClient)
            originals.removeAll()
            return (true, summary)
        } catch let error as RealAppWindowVerifierFailure {
            await cleanupAppsBestEffort(originals, using: axClient, context: "REAL OUTLOOK SIDE TRANSFER VERIFY")
            return (false, error.message)
        } catch {
            await cleanupAppsBestEffort(originals, using: axClient, context: "REAL OUTLOOK SIDE TRANSFER VERIFY")
            return (false, "Outlook side-transfer verification failed: \(String(describing: error))")
        }
    }

    private struct ProductionRuntime {
        let process: Process
        let temporaryRoot: URL
        let logURL: URL
        let ctlURL: URL
        let consoleHandle: FileHandle
    }

    private static func startProductionRuntime() throws -> ProductionRuntime {
        let appURL = try builtProduct(named: "NarwhalApp")
        let ctlURL = try builtProduct(named: "NarwhalCtl")
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-production-runtime-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = temporaryRoot.appendingPathComponent("config", isDirectory: true)
        let stateDirectory = temporaryRoot.appendingPathComponent("state", isDirectory: true)
        let logDirectory = temporaryRoot.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let configURL = configDirectory.appendingPathComponent("init.lua")
        let sourceConfig = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DefaultConfig/init.lua")
        try FileManager.default.copyItem(at: sourceConfig, to: configURL)
        let stateURL = stateDirectory.appendingPathComponent("state.json")
        let logURL = logDirectory.appendingPathComponent("narwhal.log")
        let consoleURL = logDirectory.appendingPathComponent("console.log")
        _ = FileManager.default.createFile(atPath: consoleURL.path, contents: nil)
        let consoleHandle = try FileHandle(forWritingTo: consoleURL)

        let process = Process()
        process.executableURL = appURL
        process.arguments = [
            "--config", configURL.path,
            "--restore-state", stateURL.path
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
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
        return ProductionRuntime(
            process: process,
            temporaryRoot: temporaryRoot,
            logURL: logURL,
            ctlURL: ctlURL,
            consoleHandle: consoleHandle
        )
    }

    private static func builtProduct(named name: String) throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = packageRoot
            .appendingPathComponent(".build/debug", isDirectory: true)
            .appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw RealAppWindowVerifierFailure("could not locate built product at \(candidate.path)")
        }
        return candidate
    }

    private static func waitForProductionRuntime(_ runtime: ProductionRuntime) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            guard runtime.process.isRunning else {
                throw RealAppWindowVerifierFailure(
                    "production NarwhalApp exited during startup with status \(runtime.process.terminationStatus)"
                )
            }
            let log = (try? String(contentsOf: runtime.logURL, encoding: .utf8)) ?? ""
            if log.contains("Accessibility trusted"),
               log.contains("Layout command loop ready"),
               FileManager.default.fileExists(atPath: IPCDefaults.socketPath) {
                return
            }
            await settleLiveVerifier(for: 0.1)
        }
        throw RealAppWindowVerifierFailure("production NarwhalApp did not become AX and IPC ready")
    }

    private static func sendProductionCommand(_ command: IPCCommandDTO) throws {
        let reply = try IPCClient(ioTimeout: 5).send(command)
        guard case .ok = reply else {
            throw RealAppWindowVerifierFailure("production IPC command failed: \(reply)")
        }
    }

    private static func stopProductionRuntime(_ runtime: ProductionRuntime) throws {
        if runtime.process.isRunning {
            try sendProductionCommand(.quit)
            let deadline = Date().addingTimeInterval(10)
            while runtime.process.isRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        guard !runtime.process.isRunning else {
            throw RealAppWindowVerifierFailure("production NarwhalApp did not exit after IPC quit")
        }
        try runtime.consoleHandle.close()
        try FileManager.default.removeItem(at: runtime.temporaryRoot)
    }

    private static func stopProductionRuntimeBestEffort(_ runtime: ProductionRuntime) {
        if runtime.process.isRunning {
            _ = try? IPCClient(ioTimeout: 1).send(.quit)
            let deadline = Date().addingTimeInterval(2)
            while runtime.process.isRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if runtime.process.isRunning {
                runtime.process.terminate()
            }
        }
        try? runtime.consoleHandle.close()
        try? FileManager.default.removeItem(at: runtime.temporaryRoot)
    }

    private static func productionTerminalFrames(
        _ originals: [RealAppOriginal],
        using axClient: AXClient
    ) throws -> [WindowID: CGRect] {
        try Dictionary(uniqueKeysWithValues: originals.map { original in
            let metadata = try currentWorkflowMetadata(for: original, using: axClient)
            return (metadata.id, metadata.frame)
        })
    }

    private static func requireProductionSideTransferLayout(
        frames: [WindowID: CGRect],
        fullHeightWindow: WindowID,
        stackedWindows: [WindowID],
        fullHeightSide: Direction,
        display: DisplayInfo,
        context: String
    ) throws {
        guard let full = frames[fullHeightWindow],
              stackedWindows.count == 2,
              let firstStacked = frames[stackedWindows[0]],
              let secondStacked = frames[stackedWindows[1]]
        else {
            throw RealAppWindowVerifierFailure("\(context) omitted expected Terminal frames")
        }
        let visible = display.visibleFrame
        let horizontalBoundary = visible.midX.rounded(.up)
        let verticalBoundary = visible.midY.rounded(.up)
        let leftCell = CGRect(
            x: visible.minX,
            y: visible.minY,
            width: horizontalBoundary - visible.minX,
            height: visible.height
        )
        let rightCell = CGRect(
            x: horizontalBoundary,
            y: visible.minY,
            width: visible.maxX - horizontalBoundary,
            height: visible.height
        )
        let expectedFull = fullHeightSide == .left ? leftCell : rightCell
        guard frameSettledOnPlan(full, expectedFull) else {
            throw RealAppWindowVerifierFailure(
                "\(context) did not expand the vacated side: "
                    + "expected=\(expectedFull) actual=\(full)"
            )
        }

        let stackCell = fullHeightSide == .left ? rightCell : leftCell
        let expectedStack = [
            CGRect(
                x: stackCell.minX,
                y: visible.minY,
                width: stackCell.width,
                height: verticalBoundary - visible.minY
            ),
            CGRect(
                x: stackCell.minX,
                y: verticalBoundary,
                width: stackCell.width,
                height: visible.maxY - verticalBoundary
            ),
        ]
        let stack = [firstStacked, secondStacked].sorted { $0.minY < $1.minY }
        guard zip(stack, expectedStack).allSatisfy(frameSettledOnPlan),
              framesDoNotVisiblyOverlap(stack[0], stack[1], tolerance: 0.5),
              framesDoNotVisiblyOverlap(full, stack[0], tolerance: 0.5),
              framesDoNotVisiblyOverlap(full, stack[1], tolerance: 0.5)
        else {
            throw RealAppWindowVerifierFailure(
                "\(context) did not leave a disjoint opposite-side stack: "
                    + "expected=\(expectedStack) actual=\(stack)"
            )
        }
        let sortedStackedWindows = stackedWindows.sorted {
            (frames[$0]?.minY ?? 0) < (frames[$1]?.minY ?? 0)
        }
        let expectedFrames = [
            fullHeightWindow: expectedFull,
            sortedStackedWindows[0]: expectedStack[0],
            sortedStackedWindows[1]: expectedStack[1],
        ]
        try requireConfiguredInnerGaps(
            plannedFrames: expectedFrames,
            actualFrames: frames,
            context: "\(context) AX",
            innerGap: Config.default.gaps.inner
        )
        try requireConfiguredInnerGaps(
            plannedFrames: expectedFrames,
            actualFrames: try matchingWindowServerFrames(frames, context: context),
            context: "\(context) WindowServer",
            innerGap: Config.default.gaps.inner
        )
    }

    private static func matchingWindowServerFrames(
        _ axFrames: [WindowID: CGRect],
        context: String
    ) throws -> [WindowID: CGRect] {
        try Dictionary(uniqueKeysWithValues: axFrames.map { windowID, axFrame in
            let serverFrame = LiveWindowServerVerification.waitForFrame(
                windowNumber: Int(windowID.raw),
                matching: axFrame,
                tolerance: frameWriteSettleTolerance
            )
            guard let serverFrame,
                  serverFrame.matches(axFrame, tolerance: frameWriteSettleTolerance)
            else {
                throw RealAppWindowVerifierFailure(
                    "\(context) WindowServer frame mismatch for \(windowID.description): "
                        + "expected AX=\(axFrame.debugDescription) "
                        + "actual=\(serverFrame?.debugDescription ?? "nil")"
                )
            }
            return (windowID, serverFrame)
        })
    }

    private static func productionBorderFrame(
        forAXFrame frame: CGRect,
        on display: DisplayInfo
    ) -> CGRect {
        let proposed = appKitFrame(forAXFrame: frame, on: display).insetBy(dx: -1, dy: -1)
        return axFrame(
            forAppKitFrame: LiveWindowServerVerification.constrainedBorderContentFrame(
                proposed,
                on: display.id
            ),
            on: display
        )
    }

    private static func requireProductionBorders(
        frames: [WindowID: CGRect],
        ownerPID: pid_t,
        display: DisplayInfo,
        context: String
    ) throws {
        let expected = frames.values.map { productionBorderFrame(forAXFrame: $0, on: display) }
        let deadline = Date().addingTimeInterval(1.2)
        var actual: [CGRect] = []
        while Date() < deadline {
            actual = productionOverlayFrames(ownerPID: ownerPID)
            if uniquelyMatchesBorderSurfaces(expected: expected, actual: actual, tolerance: 0.5) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        throw RealAppWindowVerifierFailure(
            "\(context) production borders did not match current Terminal frames: "
                + "expected=\(expected) ownerFrames=\(actual)"
        )
    }

    private static func uniquelyMatchesBorderSurfaces(
        expected: [CGRect],
        actual: [CGRect],
        tolerance: CGFloat
    ) -> Bool {
        var remaining = actual
        for frame in expected {
            guard let index = remaining.firstIndex(where: {
                LiveWindowServerVerification.borderSurfaceMatches(
                    $0,
                    contentFrame: frame,
                    tolerance: tolerance
                )
            }) else {
                return false
            }
            remaining.remove(at: index)
        }
        return true
    }

    private static func productionOverlayFrames(ownerPID: pid_t) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return windows.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid == ownerPID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == NSWindow.Level.normal.rawValue,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.narwhalIsFinitePositive
            else {
                return nil
            }
            return frame
        }
    }

    private static func runProductionPushAndCheckBorderClearing(
        executable: URL,
        windowID: WindowID,
        direction: Direction,
        movedWindowID: WindowID,
        oldWindowFrame: CGRect,
        oldBorderFrame: CGRect,
        ownerPID: pid_t,
        axClient: AXClient
    ) throws {
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "push", direction.rawValue,
            "--window", String(windowID.raw)
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()

        var observedMovement = false
        var staleBorderAfterMovement = false
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline {
            if let current = axClient.windowSnapshot().windows.first(where: { $0.id == movedWindowID })?.frame,
               !current.narwhalApproximatelyEquals(oldWindowFrame, tolerance: 0.5) {
                observedMovement = true
                if productionOverlayFrames(ownerPID: ownerPID).contains(where: {
                    LiveWindowServerVerification.borderSurfaceMatches(
                        $0,
                        contentFrame: oldBorderFrame,
                        tolerance: 0.5
                    )
                }) {
                    staleBorderAfterMovement = true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard !process.isRunning else {
            process.terminate()
            throw RealAppWindowVerifierFailure("production narwhalctl push timed out")
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(decoding: outputData, as: UTF8.self)
        guard process.terminationStatus == 0, outputText.hasPrefix("ok ipc-") else {
            throw RealAppWindowVerifierFailure(
                "production narwhalctl push failed with status \(process.terminationStatus): \(outputText)"
            )
        }
        guard observedMovement else {
            throw RealAppWindowVerifierFailure(
                "production side transfer completed without an observable real-window transition"
            )
        }
        guard !staleBorderAfterMovement else {
            throw RealAppWindowVerifierFailure(
                "production tile border remained on the vacated frame after its Terminal window moved"
            )
        }
    }

    private static func verifyThreeWindowVerticalStack(
        spec: RealAppSpec,
        label: String
    ) async -> (passed: Bool, message: String) {
        let axClient = AXClient(processID: -1, settleStrategy: .servicingRunLoop)
        var originals: [RealAppOriginal] = []
        do {
            try waitForUnlockedSession()
            let displays = DisplayClient().currentDisplays()
            let targetDisplay = try manualResizeVerificationDisplay(displays)
            var selectedIDs = Set<WindowID>()

            for index in 0..<3 {
                let original = try await launchTrackedWindow(
                    spec: spec,
                    using: axClient,
                    requiringNewWindow: true,
                    excluding: selectedIDs,
                    token: "stack-\(index)"
                )
                selectedIDs.insert(original.metadata.id)
                originals.append(original)
            }

            let frames = try await applyRealAxisLayout(
                originals,
                axis: .vertical,
                label: "three \(label) vertical stack",
                targetDisplay: targetDisplay,
                axClient: axClient,
                displays: displays
            )

            try await cleanupApps(originals, using: axClient)
            originals.removeAll()

            return (
                true,
                "three \(label) vertical command stack passed: \(frames.values.map(\.shortDescription).sorted().joined(separator: ","))"
            )
        } catch let error as RealAppWindowVerifierFailure {
            await cleanupAppsBestEffort(originals, using: axClient, context: "REAL \(label.uppercased()) STACK VERIFY")
            return (false, error.message)
        } catch {
            await cleanupAppsBestEffort(originals, using: axClient, context: "REAL \(label.uppercased()) STACK VERIFY")
            return (false, "three \(label) vertical stack verification failed: \(String(describing: error))")
        }
    }

    private static func applyRealAxisLayout(
        _ originals: [RealAppOriginal],
        axis: Axis,
        label: String,
        targetDisplay: DisplayInfo,
        axClient: AXClient,
        displays: [DisplayID: DisplayInfo],
        config: Config = .default
    ) async throws -> [WindowID: CGRect] {
        guard originals.count >= 2, let first = originals.first else {
            throw RealAppWindowVerifierFailure("\(label) requires at least two real windows")
        }

        try await stageAxisLayoutWindowsIfNeeded(
            originals,
            on: targetDisplay,
            using: axClient
        )
        let worldActor = WorldActor(config: config)
        let reporter = StartupReporter(logPath: "/tmp/narwhal-real-axis-layout.log")
        let applier = LayoutApplier(axClient: axClient, reporter: reporter)
        let windowIDs = Set(originals.map(\.metadata.id))
        let spaceID = try await refreshWorkflowWorld(
            worldActor,
            axClient: axClient,
            displays: displays,
            including: windowIDs,
            activeDisplayID: targetDisplay.id
        )
        let namedLayout = realAxisNamedLayout(
            count: originals.count,
            axis: axis,
            displaySlot: targetDisplay.slot,
            bundleID: first.bundleID
        )
        let plan: CommandPlanResult
        switch await worldActor.planNamedLayout(namedLayout, spaceID: spaceID, allowPartial: false) {
        case .success(let planned):
            plan = planned
        case .failure(let error):
            throw RealAppWindowVerifierFailure("\(label) named-layout plan failed: \(String(describing: error))")
        }

        let frames = try await applyWorkflowCommand(
            label,
            plan: { Result<CommandPlanResult, CommandError>.success(plan) },
            worldActor: worldActor,
            applier: applier,
            allowNoMove: true,
            requireNearPlan: false
        )
        try requireEqualAxisLayout(
            frames,
            windowIDs: windowIDs,
            axis: axis,
            visibleFrame: targetDisplay.visibleFrame,
            gaps: config.gaps,
            context: label
        )
        try requirePlannedRealFramesVisible(
            originals,
            plannedFrames: frames,
            using: axClient,
            context: label,
            requireNearPlan: false,
            innerGap: config.gaps.inner
        )
        try requireRealFramesDisjoint(
            originals,
            on: targetDisplay,
            using: axClient,
            context: label
        )
        return frames
    }

    private static func verifyTerminalPushSequence(
        _ keys: String,
        originals: [RealAppOriginal],
        targetDisplay: DisplayInfo,
        axClient: AXClient,
        displays: [DisplayID: DisplayInfo],
        overlay: Overlay
    ) async throws {
        guard keys.count == originals.count else {
            throw RealAppWindowVerifierFailure(
                "Terminal push sequence \(keys) has \(keys.count) keys for \(originals.count) windows"
            )
        }

        try await stageTerminalPushSequenceWindows(
            originals,
            on: targetDisplay,
            using: axClient
        )
        let worldActor = WorldActor(config: .default)
        let reporter = StartupReporter(logPath: "/tmp/narwhal-real-push-sequences.log")
        let applier = LayoutApplier(axClient: axClient, reporter: reporter)
        let windowIDs = Set(originals.map(\.metadata.id))
        _ = try await refreshWorkflowWorld(
            worldActor,
            axClient: axClient,
            displays: displays,
            including: windowIDs,
            activeDisplayID: targetDisplay.id
        )

        for (index, key) in keys.enumerated() {
            let original = originals[index]
            let direction = try terminalPushDirection(for: key)
            let metadata = try currentWorkflowMetadata(for: original, using: axClient)
            try await focusTerminalWindowForPush(
                metadata,
                using: axClient,
                context: "Terminal push sequence \(keys) step \(index + 1)"
            )
            let plannedFrames = try await applyWorkflowCommand(
                "Terminal push sequence \(keys) step \(index + 1) \(key)",
                plan: { await worldActor.planPush(metadata.id, direction: direction) },
                worldActor: worldActor,
                applier: applier,
                allowNoMove: true
            )

            let pushed = Array(originals.prefix(index + 1))
            _ = try renderTerminalBorders(
                pushed,
                using: axClient,
                overlay: overlay
            )
            try await raiseForWindowServerVerification(
                pushed,
                using: axClient,
                context: "Terminal push sequence \(keys) step \(index + 1)"
            )
            try requirePlannedRealFramesVisible(
                pushed,
                plannedFrames: plannedFrames,
                using: axClient,
                context: "Terminal push sequence \(keys) step \(index + 1)",
                requireExactPlan: true,
                gapTolerance: configuredGapTolerance
            )
            try requireRealFramesDisjoint(
                pushed,
                on: targetDisplay,
                using: axClient,
                context: "Terminal push sequence \(keys) step \(index + 1)"
            )
            try renderAndVerifyTerminalBorders(
                pushed,
                on: targetDisplay,
                using: axClient,
                overlay: overlay,
                context: "Terminal push sequence \(keys) step \(index + 1)"
            )
        }

        report("REAL PUSH SEQUENCE: \(keys) passed with \(originals.count) Terminal windows")
    }

    private static func renderTerminalBorders(
        _ originals: [RealAppOriginal],
        using axClient: AXClient,
        overlay: Overlay
    ) throws -> (targets: [FocusBorderTarget], result: OverlayRenderResult) {
        let targets = try originals.map { original in
            let metadata = try currentWorkflowMetadata(for: original, using: axClient)
            return FocusBorderTarget(window: metadata, frame: metadata.frame)
        }
        return (
            targets,
            overlay.render(OverlayModel.empty.settingTiledBorders(targets))
        )
    }

    private static func renderAndVerifyTerminalBorders(
        _ originals: [RealAppOriginal],
        on display: DisplayInfo,
        using axClient: AXClient,
        overlay: Overlay,
        context: String
    ) throws {
        let rendered = try renderTerminalBorders(originals, using: axClient, overlay: overlay)
        let targets = rendered.targets
        let result = rendered.result
        guard result.staleTiledBorderTargets.isEmpty else {
            throw RealAppWindowVerifierFailure(
                "\(context) rejected live tiled-border targets as stale: "
                    + result.staleTiledBorderTargets.map(\.description).joined(separator: ",")
            )
        }

        let expectedIDs = targets.map(\.windowID).sorted { $0.raw < $1.raw }
        guard overlay.debugTiledBorderWindowIDs() == expectedIDs else {
            throw RealAppWindowVerifierFailure(
                "\(context) rendered wrong tiled borders: expected="
                    + expectedIDs.map(\.description).joined(separator: ",")
                    + " actual="
                    + overlay.debugTiledBorderWindowIDs().map(\.description).joined(separator: ",")
            )
        }

        for target in targets {
            let proposedAppKitFrame = appKitFrame(
                forAXFrame: target.frame,
                on: display
            ).insetBy(dx: -1, dy: -1)
            let expectedAppKitFrame = LiveWindowServerVerification.constrainedBorderContentFrame(
                proposedAppKitFrame,
                on: display.id
            )
            guard let actualAppKitFrame = overlay.debugTiledBorderFrame(for: target.windowID),
                  actualAppKitFrame.matches(expectedAppKitFrame, tolerance: 0.5),
                  let geometry = overlay.debugTiledBorderGeometrySnapshot(for: target.windowID),
                  geometry.strokeRect.matches(
                      CGRect(origin: .zero, size: expectedAppKitFrame.size).insetBy(dx: 1, dy: 1),
                      tolerance: 0.5
                  ),
                  geometry.pathBoundingBox.matches(geometry.strokeRect, tolerance: 0.5),
                  overlay.debugTiledBorderIsVisuallyVisible(for: target.windowID),
                  let windowNumber = overlay.debugTiledBorderWindowNumber(for: target.windowID)
            else {
                throw RealAppWindowVerifierFailure(
                    "\(context) tiled border for \(target.windowID.description) was missing, hidden, or misplaced: "
                        + "expected=\(expectedAppKitFrame.debugDescription) "
                        + "actual=\(String(describing: overlay.debugTiledBorderFrame(for: target.windowID)))"
                )
            }

            let expectedWindowServerFrame = axFrame(
                forAppKitFrame: expectedAppKitFrame,
                on: display
            )
            let serverFrame = LiveWindowServerVerification.waitForBorderSurface(
                windowNumber: windowNumber,
                contentFrame: expectedWindowServerFrame,
                tolerance: 0.5
            )
            guard let serverFrame,
                  LiveWindowServerVerification.borderSurfaceMatches(
                      serverFrame,
                      contentFrame: expectedWindowServerFrame,
                      tolerance: 0.5
                  )
            else {
                throw RealAppWindowVerifierFailure(
                    "\(context) tiled border for \(target.windowID.description) was not visible at its expected WindowServer frame: "
                        + "expected=\(expectedWindowServerFrame.debugDescription) "
                        + "actual=\(serverFrame?.debugDescription ?? "nil")"
                )
            }
        }
    }

    private static func appKitFrame(forAXFrame frame: CGRect, on display: DisplayInfo) -> CGRect {
        let screenFrame = screen(for: display.id)?.frame ?? display.frame
        return CGRect(
            x: screenFrame.minX + (frame.minX - display.frame.minX),
            y: screenFrame.minY + (display.frame.maxY - frame.maxY),
            width: frame.width,
            height: frame.height
        )
    }

    private static func axFrame(forAppKitFrame frame: CGRect, on display: DisplayInfo) -> CGRect {
        let screenFrame = screen(for: display.id)?.frame ?? display.frame
        return CGRect(
            x: display.frame.minX + (frame.minX - screenFrame.minX),
            y: display.frame.maxY - (frame.maxY - screenFrame.minY),
            width: frame.width,
            height: frame.height
        )
    }

    private static func screen(for displayID: DisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID.raw
        }
    }

    private static func focusTerminalWindowForPush(
        _ metadata: WindowMetadata,
        using axClient: AXClient,
        context: String
    ) async throws {
        if case .success = await axClient.focusWindow(metadata) {
            await settleLiveVerifier(for: 0.12)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"Terminal\" to set index of window id \(metadata.id.raw) to 1",
            "-e",
            "tell application \"Terminal\" to activate"
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RealAppWindowVerifierFailure(
                "\(context) could not bring verifier-created \(metadata.id.description) to the front"
            )
        }
        await settleLiveVerifier(for: 0.12)
        switch await axClient.focusWindow(metadata) {
        case .success:
            await settleLiveVerifier(for: 0.12)
        case .failure(let error):
            throw RealAppWindowVerifierFailure(
                "\(context) could not focus verifier-created \(metadata.id.description): \(error.description)"
            )
        }
    }

    private static func raiseForWindowServerVerification(
        _ originals: [RealAppOriginal],
        using axClient: AXClient,
        context: String
    ) async throws {
        for original in originals {
            let metadata = try currentWorkflowMetadata(for: original, using: axClient)
            switch await axClient.focusWindow(metadata) {
            case .success:
                await settleLiveVerifier(for: 0.05)
            case .failure(let error):
                throw RealAppWindowVerifierFailure(
                    "\(context) could not raise \(metadata.id.description) for WindowServer verification: \(error.description)"
                )
            }
        }
    }

    private static func terminalPushDirection(for key: Character) throws -> Direction {
        switch key {
        case "H": .left
        case "L": .right
        case "J": .down
        case "K": .up
        default:
            throw RealAppWindowVerifierFailure("unsupported Terminal push-sequence key \(key)")
        }
    }

    private static func stageTerminalPushSequenceWindows(
        _ originals: [RealAppOriginal],
        on display: DisplayInfo,
        using axClient: AXClient
    ) async throws {
        let columns = 4
        let rows = originals.count > columns ? 2 : 1
        let cellWidth = display.visibleFrame.width / CGFloat(columns)
        let cellHeight = display.visibleFrame.height / CGFloat(rows)
        let requests = try originals.enumerated().map { index, original in
            let metadata = try currentWorkflowMetadata(for: original, using: axClient)
            let target = canonicalFrameWriteTarget(CGRect(
                x: display.visibleFrame.minX + CGFloat(index % columns) * cellWidth,
                y: display.visibleFrame.minY + CGFloat(index / columns) * cellHeight,
                width: cellWidth,
                height: cellHeight
            ))
            return (metadata, target)
        }
        let writer = WindowFrameWriter(axClient: axClient)
        for (metadata, target) in requests {
            switch await writer.setFrame(metadata, to: target) {
            case .converged:
                break
            case .constrained(let actual):
                throw RealAppWindowVerifierFailure(
                    "Terminal push-sequence staging constrained \(metadata.id.description): "
                        + "target=\(target.debugDescription) actual=\(actual.debugDescription)"
                )
            case .clamped(let actual, let observed):
                throw RealAppWindowVerifierFailure(
                    "Terminal push-sequence staging clamped \(metadata.id.description): "
                        + "target=\(target.debugDescription) actual=\(actual.debugDescription) "
                        + "observed=\(observed)"
                )
            case .failed(let error):
                throw RealAppWindowVerifierFailure(
                    "Terminal push-sequence staging failed for \(metadata.id.description): \(error.description)"
                )
            }
        }
        let targets = Dictionary(uniqueKeysWithValues: requests.map { ($0.0.id, $0.1) })
        try requirePlannedRealFramesVisible(
            originals,
            plannedFrames: targets,
            using: axClient,
            context: "Terminal push-sequence staging",
            verifyConfiguredGaps: false,
            requireExactPlan: true
        )
        try requireRealFramesDisjoint(
            originals,
            on: display,
            using: axClient,
            context: "Terminal push-sequence staging"
        )
    }

    private static func requireRealFramesDisjoint(
        _ originals: [RealAppOriginal],
        on display: DisplayInfo,
        using axClient: AXClient,
        context: String
    ) throws {
        let frames = try originals.map { original in
            try currentWorkflowMetadata(for: original, using: axClient).frame
        }
        for frame in frames {
            try requireFrame(frame, isOn: display, context: context)
        }
        for first in frames.indices {
            for second in frames.indices where second > first {
                guard framesDoNotVisiblyOverlap(
                    frames[first],
                    frames[second],
                    tolerance: 0.5
                ) else {
                    throw RealAppWindowVerifierFailure(
                        "\(context) left real windows overlapping: first=\(frames[first]) second=\(frames[second])"
                    )
                }
            }
        }
    }

    private static func stageAxisLayoutWindowsIfNeeded(
        _ originals: [RealAppOriginal],
        on display: DisplayInfo,
        using axClient: AXClient
    ) async throws {
        let visible = display.visibleFrame
        var movedWindow = false
        for (index, original) in originals.enumerated() {
            let metadata = try currentWorkflowMetadata(for: original, using: axClient)
            let intersection = metadata.frame.intersection(visible)
            if !intersection.isNull, intersection.area >= metadata.frame.area * 0.80 {
                continue
            }

            let inset: CGFloat = 24
            let offset = CGFloat(index) * 18
            let target = CGRect(
                x: visible.minX + inset + offset,
                y: visible.minY + inset + offset,
                width: min(
                    visible.width - inset * 2,
                    max(original.spec.minimumWindowSize.width, visible.width * 0.42)
                ),
                height: min(
                    visible.height - inset * 2,
                    max(original.spec.minimumWindowSize.height, visible.height * 0.42)
                )
            ).standardized
            try await focusIfPossible(
                metadata,
                appName: "\(original.spec.name) axis-layout staging",
                using: axClient
            )
            let actual = try await verifyFrameWrite(
                target,
                metadata: metadata,
                appName: "\(original.spec.name) axis-layout staging",
                step: index + 1,
                using: axClient
            )
            try requireFrame(actual, isOn: display, context: "\(original.spec.name) axis-layout staging")
            movedWindow = true
        }
        if movedWindow {
            await settleLiveVerifier(for: 0.16)
        }
    }

    private static func realAxisNamedLayout(
        count: Int,
        axis: Axis,
        displaySlot: Int,
        bundleID: String
    ) -> NamedLayout {
        NamedLayout(
            id: NamedLayoutID(rawValue: "live-\(axis.rawValue)-\(count)"),
            name: "Live \(axis.rawValue) \(count)",
            displays: [
                DisplayLayoutTemplate(
                    displaySlot: displaySlot,
                    root: .split(
                        axis: axis,
                        cells: (0..<count).map { index in
                            LayoutTemplateCell(
                                weight: 1,
                                node: .slot(LayoutTemplateSlot(
                                    id: LayoutSlotID(rawValue: "window-\(index)"),
                                    matcher: LayoutWindowMatcher(bundleID: bundleID, role: kAXWindowRole)
                                ))
                            )
                        }
                    )
                )
            ]
        )
    }

    private static func requireEqualAxisLayout(
        _ frames: [WindowID: CGRect],
        windowIDs: Set<WindowID>,
        axis: Axis,
        visibleFrame: CGRect,
        gaps: Gaps,
        context: String
    ) throws {
        guard Set(frames.keys) == windowIDs else {
            throw RealAppWindowVerifierFailure(
                "\(context) planned \(frames.count) windows instead of the expected \(windowIDs.count)"
            )
        }
        let actual = frames.values.sorted { lhs, rhs in
            axis == .horizontal ? lhs.minX < rhs.minX : lhs.minY < rhs.minY
        }
        let lengths = actual.map { axis == .horizontal ? $0.width : $0.height }
        let minimumLength = lengths.min() ?? 0
        let maximumLength = lengths.max() ?? 0
        let usableFrame = CGRect(
            x: visibleFrame.minX + gaps.outer.left,
            y: visibleFrame.minY + gaps.outer.top,
            width: visibleFrame.width - gaps.outer.left - gaps.outer.right,
            height: visibleFrame.height - gaps.outer.top - gaps.outer.bottom
        )
        let tiledBounds = usableFrame.insetBy(dx: gaps.inner / 2, dy: gaps.inner / 2)
        let coversOuterFrame = actual.first.map {
            axis == .horizontal
                ? abs($0.minX - tiledBounds.minX) <= 0.001
                : abs($0.minY - tiledBounds.minY) <= 0.001
        } == true && actual.last.map {
            axis == .horizontal
                ? abs($0.maxX - tiledBounds.maxX) <= 0.001
                : abs($0.maxY - tiledBounds.maxY) <= 0.001
        } == true
        let sharedEdges = zip(actual, actual.dropFirst()).allSatisfy { leading, trailing in
            axis == .horizontal
                ? abs(trailing.minX - leading.maxX - gaps.inner) <= 0.001
                : abs(trailing.minY - leading.maxY - gaps.inner) <= 0.001
        }
        let crossAxisMatches = actual.allSatisfy { cell in
            switch axis {
            case .horizontal:
                abs(cell.minY - tiledBounds.minY) <= 0.001
                    && abs(cell.height - tiledBounds.height) <= 0.001
            case .vertical:
                abs(cell.minX - tiledBounds.minX) <= 0.001
                    && abs(cell.width - tiledBounds.width) <= 0.001
            }
        }
        let internalBoundariesAreRepresentable = actual.dropFirst().allSatisfy { cell in
            let boundary = axis == .horizontal ? cell.minX : cell.minY
            return abs(boundary - boundary.rounded()) <= 0.001
        }
        guard coversOuterFrame,
              sharedEdges,
              crossAxisMatches,
              internalBoundariesAreRepresentable,
              maximumLength - minimumLength <= 1
        else {
            throw RealAppWindowVerifierFailure(
                "\(context) was not an equal representable \(axis.rawValue) layout: actual=\(actual)"
            )
        }
    }

    private static func verifyOutlookSideTransferWorkflow(
        leftTerminal: RealAppOriginal,
        rightTerminal: RealAppOriginal,
        outlook: RealAppOriginal,
        targetDisplay: DisplayInfo,
        axClient: AXClient,
        displays: [DisplayID: DisplayInfo]
    ) async throws -> String {
        let worldActor = WorldActor(config: .default)
        let reporter = StartupReporter(logPath: "/tmp/narwhal-real-outlook-side-transfer.log")
        let applier = LayoutApplier(axClient: axClient, reporter: reporter)
        let originals = [leftTerminal, rightTerminal, outlook]

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        var current = try currentWorkflowMetadata(for: leftTerminal, using: axClient)
        try await focusIfPossible(current, appName: "Outlook transfer left Terminal", using: axClient)
        try await applyWorkflowCommand(
            "Outlook transfer stage left Terminal",
            plan: { await worldActor.planPush(current.id, direction: .left) },
            worldActor: worldActor,
            applier: applier,
            allowConstraintRetry: false
        )

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        current = try currentWorkflowMetadata(for: rightTerminal, using: axClient)
        try await focusIfPossible(current, appName: "Outlook transfer right Terminal", using: axClient)
        let initialFrames = try await applyWorkflowCommand(
            "Outlook transfer stage right Terminal",
            plan: { await worldActor.planPush(current.id, direction: .right) },
            worldActor: worldActor,
            applier: applier,
            allowConstraintRetry: false
        )
        try requireInitialOutlookSideTransferLayout(
            initialFrames,
            leftTerminalID: leftTerminal.metadata.id,
            rightTerminalID: rightTerminal.metadata.id,
            visibleFrame: targetDisplay.visibleFrame
        )
        try requirePlannedRealFramesVisible(
            [leftTerminal, rightTerminal],
            plannedFrames: initialFrames,
            using: axClient,
            context: "Outlook transfer initial left-right split"
        )
        report("REAL OUTLOOK SIDE TRANSFER: two full-height Terminal halves staged")
        await settleLiveVerifier(for: outlookStageObservationDuration)

        for direction in [Direction.left, .right, .left] {
            let frames = try await pushOutlook(
                outlook,
                direction: direction,
                worldActor: worldActor,
                applier: applier,
                axClient: axClient,
                displays: displays
            )
            try requireOutlookSideTransferLayout(
                frames,
                outlookOn: direction,
                leftTerminalID: leftTerminal.metadata.id,
                rightTerminalID: rightTerminal.metadata.id,
                outlookID: outlook.metadata.id,
                visibleFrame: targetDisplay.visibleFrame
            )
            try requirePlannedRealFramesVisible(
                originals,
                plannedFrames: frames,
                using: axClient,
                context: "Outlook \(direction.rawValue) transfer"
            )
            report("REAL OUTLOOK SIDE TRANSFER: Outlook moved \(direction.rawValue); vacated side expanded")
            await settleLiveVerifier(for: outlookStageObservationDuration)
        }

        let finalTerminal = try currentWorkflowMetadata(for: rightTerminal, using: axClient)
        return "Outlook left-right-left kept 50/50 stacks; Terminal expanded to \(finalTerminal.frame.shortDescription)"
    }

    private static func pushOutlook(
        _ outlook: RealAppOriginal,
        direction: Direction,
        worldActor: WorldActor,
        applier: LayoutApplier,
        axClient: AXClient,
        displays: [DisplayID: DisplayInfo]
    ) async throws -> [WindowID: CGRect] {
        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        let current = try currentWorkflowMetadata(for: outlook, using: axClient)
        try await focusIfPossible(current, appName: "Microsoft Outlook push \(direction.rawValue)", using: axClient)
        return try await applyWorkflowCommand(
            "Microsoft Outlook push \(direction.rawValue)",
            plan: { await worldActor.planPush(current.id, direction: direction) },
            worldActor: worldActor,
            applier: applier,
            allowConstraintRetry: false
        )
    }

    private static func launchChromeVerificationWindow(token: String) throws -> URL {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        )
        let page = try browserVerificationPage(browser: "Chrome", token: token)
        var callerOwnsPage = false
        defer {
            if !callerOwnsPage {
                try? FileManager.default.removeItem(at: page)
            }
        }
        process.arguments = [
            "--new-window",
            page.absoluteString
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RealAppWindowVerifierFailure("Google Chrome new-window launch failed with status \(process.terminationStatus)")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        callerOwnsPage = true
        return page
    }

    private static func launchFirefoxVerificationWindow(token: String) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox")
        let page = try browserVerificationPage(browser: "Firefox", token: token)
        var callerOwnsPage = false
        defer {
            if !callerOwnsPage {
                try? FileManager.default.removeItem(at: page)
            }
        }
        process.arguments = [
            "--new-window",
            page.absoluteString
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RealAppWindowVerifierFailure("Firefox new-window launch failed with status \(process.terminationStatus)")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        callerOwnsPage = true
        return page
    }

    private static func browserVerificationPage(browser: String, token: String) throws -> URL {
        let title = "Narwhal \(browser) Verifier \(token)-\(UUID().uuidString)"
        let html = "<!doctype html><meta charset=utf-8><title>\(title)</title><main>\(title)</main>"
        let page = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-browser-verifier-\(UUID().uuidString).html")
        try Data(html.utf8).write(to: page, options: .atomic)
        return page
    }

    private static func verifyApp(_ spec: RealAppSpec) async -> (passed: Bool, message: String) {
        do {
            try waitForUnlockedSession()
            let displays = DisplayClient().currentDisplays()
            guard !displays.isEmpty else {
                throw RealAppWindowVerifierFailure("no displays available")
            }
            guard displays.values.contains(where: { $0.visibleFrame.width >= 900 && $0.visibleFrame.height >= 620 }) else {
                throw RealAppWindowVerifierFailure("real app verification requires a display at least 900x620")
            }

            return (true, "real app frame verification passed: \(try await verify(spec: spec, displays: displays))")
        } catch let error as RealAppWindowVerifierFailure {
            return (false, error.message)
        } catch {
            return (false, "real app verification failed: \(String(describing: error))")
        }
    }

    private static func waitForUnlockedSession() throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !realAppSessionIsLocked() {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        throw RealAppWindowVerifierFailure("real app verification requires an unlocked user session")
    }

    private static func realAppSessionIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
    }

    private static func verify(
        spec: RealAppSpec,
        displays: [DisplayID: DisplayInfo]
    ) async throws -> String {
        let axClient = AXClient(processID: -1, settleStrategy: .servicingRunLoop)
        let original = try await launchTrackedWindow(
            spec: spec,
            using: axClient,
            requiringNewWindow: spec.pattern == .browser,
            token: "direct"
        )
        do {
            let restoreFrame = original.frame
            switch await axClient.focusWindow(original.metadata) {
            case .success:
                break
            case .failure(let error):
                print("REAL APP VERIFY: \(spec.name) focus was unavailable before frame writes: \(error.description)")
            }

            let display = displayContaining(original.frame, displays: displays)
                ?? displays.values.sorted(by: { $0.slot < $1.slot }).first!
            if case .browser = spec.pattern {
                try await normalizeFreshBrowserWindow(
                    original.metadata,
                    appName: spec.name,
                    in: display.visibleFrame,
                    using: axClient
                )
            }
            let targets = try targetFrames(in: display.visibleFrame, originalFrame: original.frame, spec: spec)
            var actuals: [CGRect] = []

            for (index, target) in targets.enumerated() {
                let actual = try await verifyFrameWrite(
                    target,
                    metadata: original.metadata,
                    appName: spec.name,
                    step: index + 1,
                    using: axClient
                )
                actuals.append(actual)
                LiveWindowServerVerification.reviewPause(
                    "\(spec.name) step \(index + 1) matched real app frame \(actual.debugDescription)"
                )
            }

            let movedAway = actuals.contains {
                !$0.matches(restoreFrame, tolerance: frameWriteSettleTolerance)
            }
            guard movedAway else {
                throw RealAppWindowVerifierFailure("\(spec.name) did not visibly move away from its original frame")
            }

            try await cleanupApp(original, using: axClient)
            return "\(spec.name)=\(actuals.map(\.shortDescription).joined(separator: ","))"
        } catch {
            await cleanupAppsBestEffort([original], using: axClient, context: "REAL APP VERIFY")
            throw error
        }
    }

    private static func verifyRealCommandWorkflows(displays: [DisplayID: DisplayInfo]) async throws -> String {
        let specs = commonWorkflowSpecs()
        let axClient = AXClient(processID: -1, settleStrategy: .servicingRunLoop)
        var originals: [RealAppOriginal] = []
        var skipped: [String] = []
        do {
            for spec in specs {
                do {
                    originals.append(try await launchTrackedWindow(
                        spec: spec,
                        using: axClient,
                        requiringNewWindow: true,
                        token: "workflow"
                    ))
                } catch {
                    if spec.required || spec.pattern == .browser || spec.pattern == .terminal {
                        throw error
                    }
                    skipped.append("\(spec.name): \(String(describing: error))")
                    continue
                }
            }

            guard !originals.isEmpty else {
                throw RealAppWindowVerifierFailure("no real workflow apps were available")
            }

            var summaries: [String] = []
            summaries.append(try await verifyChromeOverFirefoxResizeWorkflow(
                originals,
                axClient: axClient,
                displays: displays
            ))
            for original in originals {
                summaries.append(try await verifySingleAppWorkflow(
                    original,
                    axClient: axClient,
                    displays: displays
                ))
            }
            summaries.append(try await verifyMixedAppWorkflow(
                originals,
                axClient: axClient,
                displays: displays
            ))

            try await cleanupApps(originals, using: axClient)
            originals.removeAll()
            return "\(summaries.joined(separator: "; ")) skipped=\(skipped.isEmpty ? "none" : skipped.joined(separator: ","))"
        } catch {
            await cleanupAppsBestEffort(originals, using: axClient, context: "REAL APP WORKFLOW VERIFY")
            throw error
        }
    }

    private static func verifySingleAppWorkflow(
        _ original: RealAppOriginal,
        axClient: AXClient,
        displays: [DisplayID: DisplayInfo]
    ) async throws -> String {
        let worldActor = WorldActor(config: .default)
        let reporter = StartupReporter(logPath: "/tmp/narwhal-real-app-workflows.log")
        let applier = LayoutApplier(axClient: axClient, reporter: reporter)

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        var current = try currentWorkflowMetadata(for: original, using: axClient)
        try await focusIfPossible(current, appName: original.spec.name, using: axClient)

        for direction in original.spec.workflowDirections {
            try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
            current = try currentWorkflowMetadata(for: original, using: axClient)
            try await applyWorkflowCommand(
                "\(original.spec.name) push \(direction.rawValue)",
                plan: { await worldActor.planPush(current.id, direction: direction) },
                worldActor: worldActor,
                applier: applier
            )
        }

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        current = try currentWorkflowMetadata(for: original, using: axClient)
        try await applyWorkflowCommand(
            "\(original.spec.name) toggle float",
            plan: { await worldActor.planToggleFloat(current.id) },
            worldActor: worldActor,
            applier: applier,
            allowNoMove: true
        )
        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        current = try currentWorkflowMetadata(for: original, using: axClient)
        try await applyWorkflowCommand(
            "\(original.spec.name) push left after toggle",
            plan: { await worldActor.planPush(current.id, direction: .left) },
            worldActor: worldActor,
            applier: applier
        )

        return "\(original.spec.name): single-app push matrix"
    }

    private static func verifyMixedAppWorkflow(
        _ originals: [RealAppOriginal],
        axClient: AXClient,
        displays: [DisplayID: DisplayInfo]
    ) async throws -> String {
        let worldActor = WorldActor(config: .default)
        let reporter = StartupReporter(logPath: "/tmp/narwhal-real-app-workflows.log")
        let applier = LayoutApplier(axClient: axClient, reporter: reporter)
        let browser = originals.first { $0.spec.pattern == .browser }
        let companions = originals
            .filter { $0.metadata.id != browser?.metadata.id }
            .prefix(2)
        let sequence = Array(companions) + (browser.map { [$0] } ?? [])
        guard sequence.count >= 2 else {
            throw RealAppWindowVerifierFailure("mixed real-app workflow needs at least two usable real app windows")
        }

        let directions: [Direction] = [.right, .left, .left, .up]
        for (index, entry) in sequence.enumerated() {
            try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
            let current = try currentWorkflowMetadata(for: entry, using: axClient)
            try await focusIfPossible(current, appName: entry.spec.name, using: axClient)
            let direction = directions[min(index, directions.count - 1)]
            try await applyWorkflowCommand(
                "mixed \(entry.spec.name) push \(direction.rawValue)",
                plan: { await worldActor.planPush(current.id, direction: direction) },
                worldActor: worldActor,
                applier: applier
            )
        }

        let resizeTarget = browser ?? sequence.last!
        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        let currentResizeTarget = try currentWorkflowMetadata(for: resizeTarget, using: axClient)
        try await applyWorkflowCommand(
            "mixed \(resizeTarget.spec.name) resize up",
            plan: { await worldActor.planResize(currentResizeTarget.id, direction: .up, delta: 0.10) },
            worldActor: worldActor,
            applier: applier
        )

        try await applyWorkflowCommand(
            "mixed balance real-app workspace",
            plan: { await worldActor.planBalanceWorkspace(containing: currentResizeTarget.id) },
            worldActor: worldActor,
            applier: applier,
            allowNoMove: true
        )

        return "mixed-app workflow apps=\(sequence.map { $0.spec.name }.joined(separator: ","))"
    }

    private static func verifyChromeOverFirefoxResizeWorkflow(
        _ originals: [RealAppOriginal],
        axClient: AXClient,
        displays: [DisplayID: DisplayInfo]
    ) async throws -> String {
        guard let chrome = originals.first(where: { $0.spec.name == "Google Chrome" }),
              let firefox = originals.first(where: { $0.spec.name == "Firefox" })
        else {
            throw RealAppWindowVerifierFailure(
                "Chrome over Firefox resize requires both Google Chrome and Firefox"
            )
        }
        guard let companion = originals.first(where: { original in
            original.metadata.id != chrome.metadata.id && original.metadata.id != firefox.metadata.id
        }) else {
            throw RealAppWindowVerifierFailure("Chrome over Firefox resize needs a third companion window")
        }

        let worldActor = WorldActor(config: .default)
        let reporter = StartupReporter(logPath: "/tmp/narwhal-real-app-workflows.log")
        let applier = LayoutApplier(axClient: axClient, reporter: reporter)
        let targetDisplay = try manualResizeVerificationDisplay(displays)

        try await stageManualResizeWindows(
            [companion, chrome, firefox],
            on: targetDisplay,
            using: axClient
        )

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        let companionWindow = try currentWorkflowMetadata(for: companion, using: axClient)
        try await focusIfPossible(companionWindow, appName: companion.spec.name, using: axClient)
        try await applyWorkflowCommand(
            "Chrome over Firefox companion push right",
            plan: { await worldActor.planPush(companionWindow.id, direction: .right) },
            worldActor: worldActor,
            applier: applier
        )

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        let chromeWindow = try currentWorkflowMetadata(for: chrome, using: axClient)
        try await focusIfPossible(chromeWindow, appName: chrome.spec.name, using: axClient)
        try await applyWorkflowCommand(
            "Chrome over Firefox Chrome push left",
            plan: { await worldActor.planPush(chromeWindow.id, direction: .left) },
            worldActor: worldActor,
            applier: applier
        )

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        let firefoxWindow = try currentWorkflowMetadata(for: firefox, using: axClient)
        try await focusIfPossible(firefoxWindow, appName: firefox.spec.name, using: axClient)
        try await applyWorkflowCommand(
            "Chrome over Firefox Firefox push left",
            plan: { await worldActor.planPush(firefoxWindow.id, direction: .left) },
            worldActor: worldActor,
            applier: applier
        )

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        var chromeBefore = try currentWorkflowMetadata(for: chrome, using: axClient)
        var firefoxBefore = try currentWorkflowMetadata(for: firefox, using: axClient)
        guard chromeBefore.frame.midY < firefoxBefore.frame.midY else {
            throw RealAppWindowVerifierFailure(
                "Chrome over Firefox resize precondition failed: Chrome was not above Firefox; chrome=\(chromeBefore.frame.debugDescription) firefox=\(firefoxBefore.frame.debugDescription)"
            )
        }

        try await focusIfPossible(firefoxBefore, appName: firefox.spec.name, using: axClient)
        try await applyWorkflowCommand(
            "Chrome over Firefox Firefox reserve shrink room",
            plan: { await worldActor.planResize(firefoxBefore.id, direction: .up, delta: Self.browserResizeReserveDelta) },
            worldActor: worldActor,
            applier: applier
        )

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        chromeBefore = try currentWorkflowMetadata(for: chrome, using: axClient)
        firefoxBefore = try currentWorkflowMetadata(for: firefox, using: axClient)
        guard chromeBefore.frame.midY < firefoxBefore.frame.midY else {
            throw RealAppWindowVerifierFailure(
                "Chrome over Firefox reserve-shrink precondition failed: Chrome was not above Firefox; chrome=\(chromeBefore.frame.debugDescription) firefox=\(firefoxBefore.frame.debugDescription)"
            )
        }

        try await focusIfPossible(chromeBefore, appName: chrome.spec.name, using: axClient)
        let coordinatedResizeStarted = ProcessInfo.processInfo.systemUptime
        let resizePlannedFrames = try await applyWorkflowCommand(
            "Chrome over Firefox Chrome resize down",
            plan: { await worldActor.planResize(chromeBefore.id, direction: .down, delta: 0.10) },
            worldActor: worldActor,
            applier: applier
        )
        let coordinatedResizeDuration = ProcessInfo.processInfo.systemUptime - coordinatedResizeStarted
        guard coordinatedResizeDuration <= Self.coordinatedResizeDeadline else {
            throw RealAppWindowVerifierFailure(
                "Chrome over Firefox coordinated resize exceeded visible handoff deadline: "
                    + "duration=\(coordinatedResizeDuration)s deadline=\(Self.coordinatedResizeDeadline)s"
            )
        }

        let chromeAfter = try currentWorkflowMetadata(for: chrome, using: axClient)
        let firefoxAfter = try currentWorkflowMetadata(for: firefox, using: axClient)
        let plannedChromeFrame = try requireFrame(
            chromeAfter.frame,
            matchesPlannedWindow: chromeAfter.id,
            in: resizePlannedFrames,
            context: "Chrome over Firefox Chrome after resize"
        )
        let plannedFirefoxFrame = try requireFrame(
            firefoxAfter.frame,
            matchesPlannedWindow: firefoxAfter.id,
            in: resizePlannedFrames,
            context: "Chrome over Firefox Firefox after resize"
        )
        guard plannedChromeFrame.height > chromeBefore.frame.height + frameWriteSettleTolerance else {
            throw RealAppWindowVerifierFailure(
                "Chrome over Firefox resize plan did not grow Chrome: "
                    + "before=\(chromeBefore.frame.debugDescription) "
                    + "planned=\(plannedChromeFrame.debugDescription)"
            )
        }
        guard plannedFirefoxFrame.height < firefoxBefore.frame.height - frameWriteSettleTolerance else {
            throw RealAppWindowVerifierFailure(
                "Chrome over Firefox resize plan did not shrink Firefox: "
                    + "before=\(firefoxBefore.frame.debugDescription) "
                    + "planned=\(plannedFirefoxFrame.debugDescription)"
            )
        }
        guard plannedChromeFrame.maxY <= plannedFirefoxFrame.minY + frameWriteSettleTolerance else {
            throw RealAppWindowVerifierFailure(
                "Chrome over Firefox resize plan left the browser stack inconsistent: "
                    + "chrome=\(plannedChromeFrame.debugDescription) "
                    + "firefox=\(plannedFirefoxFrame.debugDescription)"
            )
        }
        guard framesDoNotVisiblyOverlap(
            chromeAfter.frame,
            firefoxAfter.frame,
            tolerance: 0.5
        ) else {
            throw RealAppWindowVerifierFailure(
                "Chrome over Firefox resize left real browser windows overlapping: "
                    + "chrome=\(chromeAfter.frame.debugDescription) "
                    + "firefox=\(firefoxAfter.frame.debugDescription)"
            )
        }

        return "chrome-over-firefox resize duration=\(coordinatedResizeDuration)s chrome=\(chromeAfter.frame.shortDescription) firefox=\(firefoxAfter.frame.shortDescription)"
    }

    private static func verifyChromeFirefoxManualResizeWorkflow(
        _ originals: [RealAppOriginal],
        targetDisplay: DisplayInfo,
        axClient: AXClient,
        runtime: ProductionRuntimeHarness,
        innerGap: Double
    ) async throws -> String {
        let chrome = try requireOriginal(named: "Google Chrome", in: originals)
        let firefox = try requireOriginal(named: "Firefox", in: originals)
        let companion = try requireOriginal(named: "Terminal", in: originals)
        let companionWindow = try currentWorkflowMetadata(for: companion, using: axClient)
        try await focusIfPossible(companionWindow, appName: companion.spec.name, using: axClient)
        try runtime.send(.push(windowID: companionWindow.id, direction: .right))

        let chromeWindow = try currentWorkflowMetadata(for: chrome, using: axClient)
        try await focusIfPossible(chromeWindow, appName: chrome.spec.name, using: axClient)
        try runtime.send(.push(windowID: chromeWindow.id, direction: .left))

        let firefoxWindow = try currentWorkflowMetadata(for: firefox, using: axClient)
        try await focusIfPossible(firefoxWindow, appName: firefox.spec.name, using: axClient)
        try runtime.send(.push(windowID: firefoxWindow.id, direction: .left))

        let chromeBefore = try currentWorkflowMetadata(for: chrome, using: axClient)
        let firefoxBefore = try currentWorkflowMetadata(for: firefox, using: axClient)
        let companionBefore = try currentWorkflowMetadata(for: companion, using: axClient)
        try requireFrame(chromeBefore.frame, isOn: targetDisplay, context: "Chrome before manual resize")
        try requireFrame(firefoxBefore.frame, isOn: targetDisplay, context: "Firefox before manual resize")
        try requireFrame(companionBefore.frame, isOn: targetDisplay, context: "companion before manual resize")
        guard chromeBefore.frame.midY < firefoxBefore.frame.midY else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize precondition failed: Chrome was not above Firefox; chrome=\(chromeBefore.frame.debugDescription) firefox=\(firefoxBefore.frame.debugDescription)"
            )
        }

        var chromeAfterReserve = chromeBefore
        var firefoxAfterReserve = firefoxBefore
        for _ in 1...4 {
            if firefoxAfterReserve.frame.height - firefoxBefore.frame.height >= 56 {
                break
            }
            try await focusIfPossible(firefoxAfterReserve, appName: firefox.spec.name, using: axClient)
            try runtime.send(.resize(windowID: firefoxAfterReserve.id, direction: .up, delta: 0.35))
            chromeAfterReserve = try currentWorkflowMetadata(for: chrome, using: axClient)
            firefoxAfterReserve = try currentWorkflowMetadata(for: firefox, using: axClient)
        }
        guard chromeAfterReserve.frame.midY < firefoxAfterReserve.frame.midY else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize reserve-shrink precondition failed: Chrome was not above Firefox; chrome=\(chromeAfterReserve.frame.debugDescription) firefox=\(firefoxAfterReserve.frame.debugDescription)"
            )
        }
        guard firefoxAfterReserve.frame.height > firefoxBefore.frame.height + frameWriteSettleTolerance else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize precondition failed: Firefox reserve step did not create shrink room; before=\(firefoxBefore.frame.debugDescription) after=\(firefoxAfterReserve.frame.debugDescription)"
            )
        }

        let availableShrink = firefoxAfterReserve.frame.height
            - firefoxBefore.frame.height
            - Self.manualResizeShrinkSafety
        let growth = min(max(availableShrink, 0), 180)
        guard growth >= 48 else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize precondition failed: Firefox had insufficient shrink room; firefox=\(firefoxAfterReserve.frame.debugDescription)"
            )
        }
        let requestedChromeFrame = CGRect(
            x: chromeAfterReserve.frame.minX,
            y: chromeAfterReserve.frame.minY,
            width: chromeAfterReserve.frame.width,
            height: chromeAfterReserve.frame.height + growth
        ).standardized

        _ = try await runtime.waitUntilIdle()
        try runtime.send(.focus(windowID: chromeAfterReserve.id))
        let evidence = try runtime.captureEvidenceBaseline()
        let manualChromeFrame: CGRect
        switch await axClient.setFrame(chromeAfterReserve, to: requestedChromeFrame) {
        case .converged(let frame):
            manualChromeFrame = frame
        case .constrained(let frame):
            manualChromeFrame = frame
        case .clamped(let frame, let observed):
            guard frameWriteApproximatelySettled(
                target: requestedChromeFrame,
                actual: frame,
                tolerance: Double(frameWriteSettleTolerance)
            ) else {
                throw RealAppWindowVerifierFailure(
                    "manual browser resize Chrome direct resize clamped away from target: "
                        + "target=\(requestedChromeFrame.debugDescription) "
                        + "actual=\(frame.debugDescription) observed=\(observed)"
                )
            }
            manualChromeFrame = frame
        case .failed(let error):
            throw RealAppWindowVerifierFailure(
                "manual browser resize Chrome direct resize failed: \(error.description)"
            )
        }
        guard manualChromeFrame.matches(requestedChromeFrame, tolerance: frameWriteSettleTolerance) else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize Chrome direct resize missed target: "
                    + "target=\(requestedChromeFrame.debugDescription) "
                    + "actual=\(manualChromeFrame.debugDescription)"
            )
        }
        guard manualChromeFrame.height > chromeAfterReserve.frame.height + frameWriteSettleTolerance else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize did not visibly grow Chrome before Narwhal handling: "
                    + "before=\(chromeAfterReserve.frame.debugDescription) "
                    + "actual=\(manualChromeFrame.debugDescription)"
            )
        }

        let manualHandoffStarted = ProcessInfo.processInfo.systemUptime
        _ = try await runtime.waitForManualResize(
            from: evidence,
            deadline: Self.coordinatedResizeDeadline
        )
        let firefoxMinY = manualChromeFrame.maxY + CGFloat(innerGap)
        let expectedFirefoxFrame = CGRect(
            x: firefoxAfterReserve.frame.minX,
            y: firefoxMinY,
            width: firefoxAfterReserve.frame.width,
            height: firefoxAfterReserve.frame.maxY - firefoxMinY
        )
        let externalPlannedFrames = [
            companionBefore.id: companionBefore.frame,
            chromeAfterReserve.id: manualChromeFrame,
            firefoxAfterReserve.id: expectedFirefoxFrame
        ]
        let settleDeadline = Date().addingTimeInterval(4)
        while Date() < settleDeadline {
            let currentChrome = try currentWorkflowMetadata(for: chrome, using: axClient)
            let currentFirefox = try currentWorkflowMetadata(for: firefox, using: axClient)
            if currentChrome.frame.matches(manualChromeFrame, tolerance: frameWriteSettleTolerance),
               currentFirefox.frame.matches(expectedFirefoxFrame, tolerance: frameWriteSettleTolerance) {
                break
            }
            await settleLiveVerifier(for: 0.04)
        }
        let manualHandoffDuration = ProcessInfo.processInfo.systemUptime - manualHandoffStarted
        guard manualHandoffDuration <= Self.coordinatedResizeDeadline else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize sibling handoff exceeded visible deadline: "
                    + "duration=\(manualHandoffDuration)s deadline=\(Self.coordinatedResizeDeadline)s"
            )
        }

        let chromeAfter = try currentWorkflowMetadata(for: chrome, using: axClient)
        let firefoxAfter = try currentWorkflowMetadata(for: firefox, using: axClient)
        try requireFrame(chromeAfter.frame, isOn: targetDisplay, context: "Chrome after manual resize")
        try requireFrame(firefoxAfter.frame, isOn: targetDisplay, context: "Firefox after manual resize")
        let plannedChromeFrame = try requireFrame(
            chromeAfter.frame,
            matchesPlannedWindow: chromeAfter.id,
            in: externalPlannedFrames,
            context: "Chrome after manual resize"
        )
        let plannedFirefoxFrame = try requireFrame(
            firefoxAfter.frame,
            matchesPlannedWindow: firefoxAfter.id,
            in: externalPlannedFrames,
            context: "Firefox after manual resize"
        )
        guard chromeAfter.frame.matches(manualChromeFrame, tolerance: frameWriteSettleTolerance) else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize changed the pointer-controlled Chrome frame: "
                    + "manual=\(manualChromeFrame.debugDescription) "
                    + "after=\(chromeAfter.frame.debugDescription)"
            )
        }
        let chromeServerFrame = LiveWindowServerVerification.waitForFrame(
            windowNumber: Int(chromeAfter.id.raw),
            matching: manualChromeFrame,
            tolerance: frameWriteSettleTolerance
        )
        guard chromeServerFrame?.matches(manualChromeFrame, tolerance: frameWriteSettleTolerance) == true else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize changed the WindowServer-visible Chrome frame: "
                    + "manual=\(manualChromeFrame.debugDescription) "
                    + "after=\(chromeServerFrame?.debugDescription ?? "nil")"
            )
        }
        guard plannedChromeFrame.height >= manualChromeFrame.height - frameWriteSettleTolerance else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize plan lost Chrome's manual height: "
                    + "manual=\(manualChromeFrame.debugDescription) "
                    + "planned=\(plannedChromeFrame.debugDescription)"
            )
        }
        guard plannedFirefoxFrame.height < firefoxAfterReserve.frame.height - frameWriteSettleTolerance else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize plan did not shrink real Firefox: "
                    + "before=\(firefoxAfterReserve.frame.debugDescription) "
                    + "planned=\(plannedFirefoxFrame.debugDescription)"
            )
        }
        guard plannedFirefoxFrame.minY >= plannedChromeFrame.maxY - frameWriteSettleTolerance else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize plan left Chrome/Firefox stack inconsistent: "
                    + "chrome=\(plannedChromeFrame.debugDescription) "
                    + "firefox=\(plannedFirefoxFrame.debugDescription)"
            )
        }

        let companionAfter = try currentWorkflowMetadata(for: companion, using: axClient)
        try requireFrame(companionAfter.frame, isOn: targetDisplay, context: "companion after manual resize")
        try requireFrame(
            companionAfter.frame,
            matchesPlannedWindow: companionAfter.id,
            in: externalPlannedFrames,
            context: "companion after manual resize"
        )
        guard framesDoNotVisiblyOverlap(
            companionAfter.frame,
            chromeAfter.frame,
            tolerance: frameWriteSettleTolerance
        ),
            framesDoNotVisiblyOverlap(
                companionAfter.frame,
                firefoxAfter.frame,
                tolerance: frameWriteSettleTolerance
            ),
            framesDoNotVisiblyOverlap(
                chromeAfter.frame,
                firefoxAfter.frame,
                tolerance: 0.5
            )
        else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize left real windows overlapping: "
                    + "companion=\(companionAfter.frame.debugDescription) "
                    + "chrome=\(chromeAfter.frame.debugDescription) "
                    + "firefox=\(firefoxAfter.frame.debugDescription)"
            )
        }
        try RealFrameAssertions.requireProductionBorders(
            frames: [
                companionAfter.id: companionAfter.frame,
                chromeAfter.id: chromeAfter.frame,
                firefoxAfter.id: firefoxAfter.frame
            ],
            focusedWindowID: chromeAfter.id,
            ownerPID: runtime.process.processIdentifier,
            display: targetDisplay,
            context: "production browser manual resize"
        )
        try RealFrameAssertions.requireNoForbiddenRuntimeOutcomes(
            runtime.logText,
            context: "production browser manual resize"
        )

        return "real 3-window Chrome/Firefox manual resize duration=\(manualHandoffDuration)s companion=\(companionAfter.frame.shortDescription) chrome=\(chromeAfter.frame.shortDescription) firefox=\(firefoxAfter.frame.shortDescription)"
    }

    private static func productionManualResizeDisplay(_ displays: [DisplayID: DisplayInfo]) throws -> DisplayInfo {
        let candidates = displays.values.filter {
            $0.visibleFrame.width >= 1_200
                && $0.visibleFrame.height >= 800
                && $0.visibleFrame.width > $0.visibleFrame.height
        }
        guard let display = candidates.max(by: { $0.visibleFrame.area < $1.visibleFrame.area }) else {
            throw RealAppWindowVerifierFailure("production manual resize requires a landscape display at least 1200x800")
        }
        return display
    }

    private static func manualResizeVerificationDisplay(_ displays: [DisplayID: DisplayInfo]) throws -> DisplayInfo {
        let candidates = displays.values.filter {
            $0.visibleFrame.width >= 1_800
                && $0.visibleFrame.height >= 900
                && $0.visibleFrame.width > $0.visibleFrame.height
        }
        guard let display = candidates.max(by: { $0.visibleFrame.area < $1.visibleFrame.area }) else {
            let visible = displays.values
                .sorted { $0.slot < $1.slot }
                .map { "slot=\($0.slot) visible=\($0.visibleFrame.debugDescription)" }
                .joined(separator: "; ")
            throw RealAppWindowVerifierFailure(
                "manual browser resize verification requires a landscape display at least 1800x900; displays=[\(visible)]"
            )
        }
        return display
    }

    private static func stageOutlookSideTransferWindows(
        leftTerminal: RealAppOriginal,
        rightTerminal: RealAppOriginal,
        outlook: RealAppOriginal,
        on display: DisplayInfo,
        using axClient: AXClient
    ) async throws {
        let visible = display.visibleFrame
        let terminalWidth = max(CGFloat(480), visible.width * 0.28)
        let terminalHeight = max(CGFloat(320), visible.height * 0.34)
        let margin: CGFloat = 24
        let placements: [(RealAppOriginal, CGRect)] = [
            (
                leftTerminal,
                CGRect(
                    x: visible.minX + margin,
                    y: visible.minY + margin,
                    width: terminalWidth,
                    height: terminalHeight
                )
            ),
            (
                rightTerminal,
                CGRect(
                    x: visible.maxX - margin - terminalWidth,
                    y: visible.minY + margin,
                    width: terminalWidth,
                    height: terminalHeight
                )
            ),
            (
                outlook,
                CGRect(
                    x: visible.minX + visible.width * 0.23,
                    y: visible.minY + visible.height * 0.13,
                    width: visible.width * 0.73,
                    height: visible.height * 0.86
                )
            )
        ]

        for (index, placement) in placements.enumerated() {
            let metadata = try currentWorkflowMetadata(for: placement.0, using: axClient)
            try await focusIfPossible(metadata, appName: "\(placement.0.spec.name) Outlook-transfer staging", using: axClient)
            _ = try await verifyFrameWrite(
                placement.1.standardized,
                metadata: metadata,
                appName: "\(placement.0.spec.name) Outlook-transfer staging",
                step: index + 1,
                using: axClient
            )
        }
        await settleLiveVerifier(for: 0.16)
    }

    private static func requireOutlookSideTransferLayout(
        _ frames: [WindowID: CGRect],
        outlookOn side: Direction,
        leftTerminalID: WindowID,
        rightTerminalID: WindowID,
        outlookID: WindowID,
        visibleFrame: CGRect
    ) throws {
        let (leftHalf, rightHalf) = visibleFrame.divided(
            atDistance: visibleFrame.width / 2,
            from: .minXEdge
        )
        let (leftTop, leftBottom) = leftHalf.divided(
            atDistance: leftHalf.height / 2,
            from: .minYEdge
        )
        let (rightTop, rightBottom) = rightHalf.divided(
            atDistance: rightHalf.height / 2,
            from: .minYEdge
        )
        let expected: [WindowID: CGRect]
        switch side {
        case .left:
            expected = [
                leftTerminalID: leftTop,
                outlookID: leftBottom,
                rightTerminalID: rightHalf
            ]
        case .right:
            expected = [
                leftTerminalID: leftHalf,
                rightTerminalID: rightTop,
                outlookID: rightBottom
            ]
        case .up, .down:
            throw RealAppWindowVerifierFailure("Outlook side transfer requires a horizontal direction")
        }

        for (windowID, expectedFrame) in expected {
            guard let actualFrame = frames[windowID] else {
                throw RealAppWindowVerifierFailure(
                    "Outlook \(side.rawValue) transfer omitted planned frame for \(windowID.description)"
                )
            }
            guard actualFrame.matches(expectedFrame, tolerance: frameWriteSettleTolerance) else {
                throw RealAppWindowVerifierFailure(
                    "Outlook \(side.rawValue) transfer was not an exact half layout for \(windowID.description): "
                        + "expected=\(expectedFrame.debugDescription) actual=\(actualFrame.debugDescription)"
                )
            }
        }
    }

    private static func requireInitialOutlookSideTransferLayout(
        _ frames: [WindowID: CGRect],
        leftTerminalID: WindowID,
        rightTerminalID: WindowID,
        visibleFrame: CGRect
    ) throws {
        let (leftHalf, rightHalf) = visibleFrame.divided(
            atDistance: visibleFrame.width / 2,
            from: .minXEdge
        )
        let expected = [leftTerminalID: leftHalf, rightTerminalID: rightHalf]
        for (windowID, expectedFrame) in expected {
            guard let actualFrame = frames[windowID],
                  actualFrame.matches(expectedFrame, tolerance: frameWriteSettleTolerance)
            else {
                throw RealAppWindowVerifierFailure(
                    "Outlook transfer did not begin with two exact full-height halves for \(windowID.description): "
                        + "expected=\(expectedFrame.debugDescription) actual=\(String(describing: frames[windowID]))"
                )
            }
        }
    }

    private static func requirePlannedRealFramesVisible(
        _ originals: [RealAppOriginal],
        plannedFrames: [WindowID: CGRect],
        using axClient: AXClient,
        context: String,
        verifyConfiguredGaps: Bool = true,
        requireNearPlan: Bool = true,
        requireExactPlan: Bool = false,
        innerGap: Double = Config.default.gaps.inner,
        gapTolerance: CGFloat = configuredGapTolerance
    ) throws {
        var actualFrames: [WindowID: CGRect] = [:]
        var serverFrames: [WindowID: CGRect] = [:]
        for original in originals {
            let metadata = try currentWorkflowMetadata(for: original, using: axClient)
            guard let plannedFrame = plannedFrames[metadata.id] else {
                throw RealAppWindowVerifierFailure(
                    "\(context) omitted \(original.spec.name) from the planned layout"
                )
            }
            let expectedFrame = requireExactPlan
                ? canonicalFrameWriteTarget(plannedFrame)
                : plannedFrame
            let axMatchesPlan = requireExactPlan
                ? metadata.frame.matches(expectedFrame, tolerance: configuredGapTolerance)
                : frameSettledOnPlan(metadata.frame, expectedFrame)
            guard !requireNearPlan || axMatchesPlan else {
                throw RealAppWindowVerifierFailure(
                    "\(context) AX frame mismatch for \(original.spec.name): "
                    + "expected=\(expectedFrame.debugDescription) actual=\(metadata.frame.debugDescription)"
                )
            }
            actualFrames[metadata.id] = metadata.frame
            let serverFrame = LiveWindowServerVerification.waitForFrame(
                windowNumber: Int(metadata.id.raw),
                matching: requireExactPlan ? expectedFrame : metadata.frame,
                tolerance: requireExactPlan ? configuredGapTolerance : frameWriteSettleTolerance
            )
            let serverMatches = serverFrame.map {
                $0.matches(
                    requireExactPlan ? expectedFrame : metadata.frame,
                    tolerance: requireExactPlan ? configuredGapTolerance : frameWriteSettleTolerance
                )
            } ?? false
            guard let visibleFrame = serverFrame, serverMatches
            else {
                throw RealAppWindowVerifierFailure(
                    "\(context) WindowServer frame mismatch for \(original.spec.name): "
                        + "expected=\((requireExactPlan ? expectedFrame : metadata.frame).debugDescription) "
                        + "actual=\(serverFrame?.debugDescription ?? "nil")"
                )
            }
            serverFrames[metadata.id] = visibleFrame
        }
        if verifyConfiguredGaps {
            try requireConfiguredInnerGaps(
                plannedFrames: plannedFrames,
                actualFrames: actualFrames,
                context: "\(context) AX",
                innerGap: innerGap,
                tolerance: gapTolerance
            )
            try requireConfiguredInnerGaps(
                plannedFrames: plannedFrames,
                actualFrames: serverFrames,
                context: "\(context) WindowServer",
                innerGap: innerGap,
                tolerance: gapTolerance
            )
        }
    }

    private static func requireConfiguredInnerGaps(
        plannedFrames: [WindowID: CGRect],
        actualFrames: [WindowID: CGRect],
        context: String,
        innerGap: Double,
        tolerance: CGFloat = configuredGapTolerance
    ) throws {
        let violations = innerGapViolations(
            planned: plannedFrames,
            actual: actualFrames,
            innerGap: innerGap,
            tolerance: Double(tolerance)
        )
        guard let violation = violations.first else { return }
        throw RealAppWindowVerifierFailure(
            "\(context) did not preserve configured \(violation.axis.rawValue) gap: "
                + "before=\(violation.before.description) after=\(violation.after.description) "
                + "expected=\(violation.expected) actual=\(violation.actual)"
        )
    }

    private static func stageProductionManualResizeWindows(
        _ originals: [RealAppOriginal],
        on display: DisplayInfo,
        using axClient: AXClient
    ) async throws {
        let chrome = try requireOriginal(named: "Google Chrome", in: originals)
        let firefox = try requireOriginal(named: "Firefox", in: originals)
        let companion = try requireOriginal(named: "Terminal", in: originals)
        let visible = display.visibleFrame
        let margin: CGFloat = 20
        let halfWidth = visible.width / 2
        let placements: [(RealAppOriginal, CGRect)] = [
            (chrome, CGRect(x: visible.minX + margin, y: visible.minY + margin, width: halfWidth - margin * 2, height: 400)),
            (firefox, CGRect(x: visible.minX + margin, y: visible.maxY - 420, width: halfWidth - margin * 2, height: 400)),
            (companion, CGRect(x: visible.midX + margin, y: visible.minY + margin, width: halfWidth - margin * 2, height: visible.height - margin * 2))
        ]
        for (index, placement) in placements.enumerated() {
            let metadata = try currentWorkflowMetadata(for: placement.0, using: axClient)
            _ = try await verifyFrameWrite(
                placement.1,
                metadata: metadata,
                appName: "\(placement.0.spec.name) production staging",
                step: index + 1,
                using: axClient
            )
        }
    }

    private static func stageManualResizeWindows(
        _ originals: [RealAppOriginal],
        on display: DisplayInfo,
        using axClient: AXClient
    ) async throws {
        let chrome = try requireOriginal(named: "Google Chrome", in: originals)
        let firefox = try requireOriginal(named: "Firefox", in: originals)
        let companion = try requireOriginal(named: "Terminal", in: originals)
        let visible = display.visibleFrame
        let margin: CGFloat = 16
        let stackGap: CGFloat = 16
        let minimumChromeHeight = max(CGFloat(420), chrome.spec.minimumWindowSize.height)
        let minimumCompanionWidth = max(CGFloat(480), companion.spec.minimumWindowSize.width)
        let probeWidth = min(max(firefox.spec.minimumWindowSize.width, 1_300), visible.width - margin * 2)
        let probeHeight = min(
            max(Self.firefoxManualStagingMinimumHeight, firefox.spec.minimumWindowSize.height),
            visible.height - margin * 2
        )
        guard probeWidth > 0, probeHeight > 0 else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize staging has no usable Firefox probe frame: visible=\(visible.debugDescription)"
            )
        }

        let firefoxMetadata = try currentWorkflowMetadata(for: firefox, using: axClient)
        let probeFrame = CGRect(
            x: visible.minX + margin,
            y: visible.maxY - margin - probeHeight,
            width: probeWidth,
            height: probeHeight
        ).standardized
        var firefoxMinimumWidth = firefox.spec.minimumWindowSize.width
        var firefoxMinimumHeight = max(Self.firefoxManualStagingMinimumHeight, firefox.spec.minimumWindowSize.height)
        switch await axClient.setFrame(firefoxMetadata, to: probeFrame) {
        case .converged:
            break
        case .constrained:
            break
        case .clamped(let actual, let observed):
            firefoxMinimumWidth = max(firefoxMinimumWidth, observed.minWidth ?? actual.width)
            firefoxMinimumHeight = max(firefoxMinimumHeight, observed.minHeight ?? actual.height)
        case .failed(.frameDidNotConverge(_, let actual, _))
            where frameWriteApproximatelySettled(
                target: probeFrame,
                actual: actual,
                tolerance: Double(max(frameWriteSettleTolerance, Self.realAppFrameWriteTolerance))
            ):
            break
        case .failed(let error):
            throw RealAppWindowVerifierFailure(
                "Firefox manual-resize staging probe failed: \(error.description)"
            )
        }

        let maximumBrowserWidth = visible.width - margin * 3 - minimumCompanionWidth
        let browserWidth = min(
            max(visible.width * 0.45, firefoxMinimumWidth),
            maximumBrowserWidth
        )
        let stackHeight = visible.height - margin * 2 - stackGap
        let firefoxHeightWithShrinkRoom = firefoxMinimumHeight + Self.manualResizeShrinkReserve
        let chromeHeight = min(
            max(minimumChromeHeight, visible.height * 0.28),
            stackHeight - firefoxHeightWithShrinkRoom
        )
        let firefoxHeight = stackHeight - chromeHeight
        guard browserWidth >= firefoxMinimumWidth,
              chromeHeight >= minimumChromeHeight,
              firefoxHeight >= firefoxHeightWithShrinkRoom
        else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize staging cannot fit live Firefox constraints: visible=\(visible.debugDescription) minFirefox=(\(firefoxMinimumWidth),\(firefoxMinimumHeight))"
            )
        }
        let companionWidth = visible.width - browserWidth - margin * 3
        let companionFrame = CGRect(
            x: visible.maxX - margin - companionWidth,
            y: visible.minY + margin,
            width: companionWidth,
            height: visible.height - margin * 2
        ).standardized
        let chromeFrame = CGRect(
            x: visible.minX + margin,
            y: visible.minY + margin,
            width: browserWidth,
            height: chromeHeight
        ).standardized
        let firefoxFrame = CGRect(
            x: visible.minX + margin,
            y: chromeFrame.maxY + stackGap,
            width: browserWidth,
            height: firefoxHeight
        ).standardized

        let placements: [(RealAppOriginal, CGRect)] = [
            (companion, companionFrame),
            (chrome, chromeFrame),
            (firefox, firefoxFrame)
        ]
        for (index, placement) in placements.enumerated() {
            let metadata = try currentWorkflowMetadata(for: placement.0, using: axClient)
            try await focusIfPossible(metadata, appName: placement.0.spec.name, using: axClient)
            _ = try await verifyFrameWrite(
                placement.1,
                metadata: metadata,
                appName: "\(placement.0.spec.name) manual-resize staging",
                step: index + 1,
                using: axClient
            )
        }
        await settleLiveVerifier(for: 0.16)
    }

    private static func framesDoNotVisiblyOverlap(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull && !intersection.isInfinite else { return true }
        return intersection.width <= tolerance || intersection.height <= tolerance
    }

    private static func requireFrame(_ frame: CGRect, isOn display: DisplayInfo, context: String) throws {
        let intersection = frame.intersection(display.visibleFrame)
        guard !intersection.isNull,
              intersection.area >= frame.area * 0.80
        else {
            throw RealAppWindowVerifierFailure(
                "\(context) was not on manual-resize target display: frame=\(frame.debugDescription) display=\(display.visibleFrame.debugDescription)"
            )
        }
    }

    @discardableResult
    private static func requireFrame(
        _ frame: CGRect,
        matchesPlannedWindow windowID: WindowID,
        in plannedFrames: [WindowID: CGRect],
        context: String
    ) throws -> CGRect {
        guard let plannedFrame = plannedFrames[windowID] else {
            throw RealAppWindowVerifierFailure("\(context) had no planned frame for \(windowID.description)")
        }
        guard frameSettledOnPlan(frame, plannedFrame) else {
            throw RealAppWindowVerifierFailure(
                "\(context) did not match planned frame: "
                    + "expected=\(plannedFrame.debugDescription) "
                    + "actual=\(frame.debugDescription)"
            )
        }
        return plannedFrame
    }

    @discardableResult
    private static func refreshWorkflowWorld(
        _ worldActor: WorldActor,
        axClient: AXClient,
        displays: [DisplayID: DisplayInfo],
        including includedWindowIDs: Set<WindowID>? = nil,
        activeDisplayID: DisplayID? = nil
    ) async throws -> SpaceID {
        let fullSnapshot = axClient.windowSnapshot()
        guard fullSnapshot.quality == .complete else {
            throw RealAppWindowVerifierFailure("real workflow AX snapshot was not complete: \(fullSnapshot.quality)")
        }
        let axSnapshot = AXWindowSnapshot(
            windows: includedWindowIDs.map { included in
                fullSnapshot.windows.filter { included.contains($0.id) }
            } ?? fullSnapshot.windows,
            quality: fullSnapshot.quality
        )
        if let includedWindowIDs {
            let found = Set(axSnapshot.windows.map(\.id))
            guard found == includedWindowIDs else {
                throw RealAppWindowVerifierFailure(
                    "real workflow snapshot omitted windows \(includedWindowIDs.subtracting(found).map(\.description).sorted())"
                )
            }
        }
        let spaceClient = SpaceClient()
        let topology = spaceClient.spaceTopology(displays: displays, windows: axSnapshot.windows)
        let activeSpace: SpaceID
        if let activeDisplayID {
            guard let displaySpace = topology.activeSpaceByDisplay[activeDisplayID] else {
                throw RealAppWindowVerifierFailure(
                    "real workflow could not resolve the active Space for display \(activeDisplayID.raw)"
                )
            }
            activeSpace = displaySpace
        } else {
            switch spaceClient.activeSpaceID() {
            case .success(let spaceID):
                activeSpace = spaceID
            case .failure:
                guard let fallback = topology.primaryActiveSpace else {
                    throw RealAppWindowVerifierFailure("real workflow could not resolve an active Space")
                }
                activeSpace = fallback
            }
        }
        _ = await worldActor.refreshEnvironment(EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: displays,
            axSnapshot: axSnapshot,
            spaceTopology: topology,
            preserveSpaceLayouts: true,
            reconciliationMode: .observeOnly
        ))
        return activeSpace
    }

    @discardableResult
    private static func applyWorkflowCommand(
        _ name: String,
        plan: () async -> Result<CommandPlanResult, CommandError>,
        worldActor: WorldActor,
        applier: LayoutApplier,
        allowNoMove: Bool = false,
        allowConstraintRetry: Bool = true,
        requireNearPlan: Bool = true
    ) async throws -> [WindowID: CGRect] {
        let first = try await requireWorkflowPlan(name, plan(), allowNoMove: allowNoMove)
        var current = first
        var retryState = LayoutClampRetryState(maxAttempts: first.desiredLayout.delta.moves.count)
        var clampSummaries: [String] = []

        while true {
            if current.desiredLayout.delta.moves.isEmpty {
                await worldActor.commit(current, appliedFrames: [:])
                return current.desiredLayout.layout.tiled
            }

            let applyResult = await applier.apply(current)
            switch plannedLayoutApplyDecision(
                plan: current,
                applyResult: applyResult,
                retryOnClamp: allowConstraintRetry
            ) {
            case .commit(let appliedFrames, _):
                await worldActor.commit(current, appliedFrames: appliedFrames)
                try requireAppliedFramesVisible(
                    appliedFrames,
                    plan: current,
                    context: name,
                    requireNearPlan: requireNearPlan
                )
                return current.desiredLayout.layout.tiled

            case .fail(let failureCount, let summary):
                throw RealAppWindowVerifierFailure(
                    "\(name) failed applying \(failureCount) real app window(s): "
                        + (clampSummaries + [summary]).joined(separator: "; ")
                )

            case .clamp(let observedConstraints, let shouldRetry, let summary):
                guard allowConstraintRetry else {
                    throw RealAppWindowVerifierFailure(
                        "\(name) changed the intended geometry instead of applying the original plan: \(summary)"
                    )
                }
                await worldActor.recordObservedConstraints(observedConstraints)
                guard shouldRetry,
                      let nextRetryState = retryState.recording(observedConstraints)
                else {
                    throw RealAppWindowVerifierFailure(
                        "\(name) clamped without a new bounded constraint observation: "
                            + (clampSummaries + [summary]).joined(separator: "; ")
                    )
                }
                retryState = nextRetryState
                clampSummaries.append(summary)
                current = try await requireWorkflowPlan(
                    "\(name) retry after clamp",
                    plan(),
                    allowNoMove: allowNoMove
                )
            }
        }
    }

    private static func currentWorkflowMetadata(
        for original: RealAppOriginal,
        using axClient: AXClient
    ) throws -> WindowMetadata {
        let trackedCandidates = axClient.windowSnapshot().windows
            .filter {
                $0.bundleID.raw == original.bundleID
                    && $0.isResizable
                    && !$0.isMinimized
            }
        if let exact = trackedCandidates.first(where: { $0.id == original.metadata.id }) {
            return exact
        }
        let candidates = trackedCandidates
            .filter {
                $0.frame.width >= original.spec.minimumWindowSize.width
                    && $0.frame.height >= original.spec.minimumWindowSize.height
            }
            .sorted { $0.frame.area > $1.frame.area }
        if original.createdByVerifier {
            throw RealAppWindowVerifierFailure(
                "\(original.spec.name) verifier-created window \(original.metadata.id.description) disappeared from the AX snapshot"
            )
        }
        if let preferred = candidates.first(where: { candidate in
            original.spec.preferredTitleSubstrings.contains { token in
                candidate.title.localizedCaseInsensitiveContains(token)
            }
        }) {
            return preferred
        }
        if let sameTitle = candidates.first(where: { $0.title == original.metadata.title }) {
            return sameTitle
        }
        if let largest = candidates.first {
            return largest
        }
        throw RealAppWindowVerifierFailure(
            "\(original.spec.name) no longer has a usable AX window for workflow commands"
        )
    }

    private static func requireWorkflowPlan(
        _ context: String,
        _ result: Result<CommandPlanResult, CommandError>,
        allowNoMove: Bool = false
    ) throws -> CommandPlanResult {
        switch result {
        case .success(let plan):
            guard allowNoMove || !plan.desiredLayout.delta.moves.isEmpty else {
                throw RealAppWindowVerifierFailure("\(context) produced no visible window moves")
            }
            return plan
        case .failure(let error):
            throw RealAppWindowVerifierFailure("\(context) plan failed: \(error.message)")
        }
    }

    private static func requireAppliedFramesVisible(
        _ appliedFrames: [WindowID: CGRect],
        plan: CommandPlanResult,
        context: String,
        requireNearPlan: Bool = true
    ) throws {
        guard !appliedFrames.isEmpty else {
            throw RealAppWindowVerifierFailure("\(context) applied no frames")
        }
        let plannedFrames = plan.desiredLayout.layout.tiled
        let missingWindowIDs = plan.desiredLayout.delta.moves.keys.filter { appliedFrames[$0] == nil }
        guard missingWindowIDs.isEmpty else {
            let missing = missingWindowIDs
                .map(\.description)
                .sorted()
                .joined(separator: ",")
            throw RealAppWindowVerifierFailure("\(context) did not apply planned frames for \(missing)")
        }
        for (windowID, frame) in appliedFrames {
            guard let plannedFrame = plannedFrames[windowID] else {
                throw RealAppWindowVerifierFailure(
                    "\(context) applied unplanned frame for \(windowID.description): actual=\(frame.debugDescription)"
                )
            }
            guard !requireNearPlan || frameSettledOnPlan(frame, plannedFrame) else {
                throw RealAppWindowVerifierFailure(
                    "\(context) AX frame did not settle on plan for \(windowID.description): "
                        + "expected=\(plannedFrame.debugDescription) "
                        + "actual=\(frame.debugDescription)"
                )
            }
            let serverFrame = LiveWindowServerVerification.waitForFrame(
                windowNumber: Int(windowID.raw),
                matching: frame,
                tolerance: frameWriteSettleTolerance
            )
            guard serverFrame?.matches(frame, tolerance: frameWriteSettleTolerance) == true else {
                throw RealAppWindowVerifierFailure(
                    "\(context) WindowServer frame mismatch for \(windowID.description): "
                        + "expected=\(frame.debugDescription) "
                        + "actual=\(serverFrame?.debugDescription ?? "nil")"
                )
            }
        }
    }

    private static func frameSettledOnPlan(_ frame: CGRect, _ plannedFrame: CGRect) -> Bool {
        frameWriteNearTarget(
            target: plannedFrame,
            actual: frame,
            tolerance: Double(frameWriteSettleTolerance)
        )
    }

    private static func focusIfPossible(
        _ metadata: WindowMetadata,
        appName: String,
        using axClient: AXClient
    ) async throws {
        switch await axClient.focusWindow(metadata) {
        case .success:
            await settleLiveVerifier(for: 0.12)
        case .failure(let error):
            print("REAL APP WORKFLOW VERIFY: \(appName) focus was unavailable: \(error.description)")
        }
    }

    private static func requireOriginal(
        named name: String,
        in originals: [RealAppOriginal]
    ) throws -> RealAppOriginal {
        guard let original = originals.first(where: { $0.spec.name == name }) else {
            throw RealAppWindowVerifierFailure("missing launched real app \(name)")
        }
        return original
    }

    private static func installedBundleID(for spec: RealAppSpec) throws -> String {
        for bundleID in spec.bundleIDs {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
                return bundleID
            }
        }
        throw RealAppWindowVerifierFailure(
            "\(spec.name) is not installed; tried bundle IDs \(spec.bundleIDs.joined(separator: ", "))"
        )
    }

    private static func preexistingWindowIDs(
        spec: RealAppSpec,
        bundleID: String,
        using axClient: AXClient
    ) -> Set<WindowID> {
        Set(windows(for: spec, bundleID: bundleID, using: axClient).map(\.id))
    }

    private static func windows(
        for spec: RealAppSpec,
        bundleID: String,
        using axClient: AXClient
    ) -> [WindowMetadata] {
        let processIDs = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .map(\.processIdentifier)
        )
        let serverWindowIDs = windowServerWindowIDs(ownerNames: [spec.name, spec.launchName])
        return axClient.windowSnapshot().windows.filter {
            $0.bundleID.raw == bundleID
                || processIDs.contains($0.pid)
                || serverWindowIDs.contains($0.id)
        }
    }

    private static func windowServerWindowIDs(ownerNames: Set<String>) -> Set<WindowID> {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return Set(windows.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerName = window[kCGWindowOwnerName as String] as? String,
                  ownerNames.contains(ownerName),
                  let number = window[kCGWindowNumber as String] as? CGWindowID
            else { return nil }
            return WindowID(raw: number)
        })
    }

    private static func launchTrackedWindow(
        spec: RealAppSpec,
        using axClient: AXClient,
        requiringNewWindow: Bool,
        excluding additionalExcludedIDs: Set<WindowID> = [],
        token: String
    ) async throws -> RealAppOriginal {
        let bundleID = try installedBundleID(for: spec)
        let preexistingIDs = preexistingWindowIDs(spec: spec, bundleID: bundleID, using: axClient)
        let excludedIDs = requiringNewWindow ? preexistingIDs.union(additionalExcludedIDs) : additionalExcludedIDs
        report("REAL APP WINDOW: launching \(spec.name) verification token=\(token)")
        let verificationPage = try launch(spec: spec, bundleID: bundleID, token: token)
        defer {
            if let verificationPage {
                try? FileManager.default.removeItem(at: verificationPage)
            }
        }
        let requiredTitleSubstrings = verificationTitleSubstrings(for: spec, token: token)
        let metadata: WindowMetadata
        do {
            metadata = try await waitForUsableWindow(
                spec: spec,
                bundleID: bundleID,
                using: axClient,
                excluding: excludedIDs,
                requiredTitleSubstrings: requiredTitleSubstrings
            )
        } catch {
            if requiringNewWindow {
                await closeUntrackedVerifierWindows(
                    spec: spec,
                    bundleID: bundleID,
                    excluding: excludedIDs,
                    using: axClient
                )
            }
            throw error
        }
        let createdByVerifier = !preexistingIDs.contains(metadata.id)
        guard !requiringNewWindow || createdByVerifier else {
            throw RealAppWindowVerifierFailure(
                "\(spec.name) launch reused preexisting window \(metadata.id.description) instead of creating a verification window"
            )
        }
        report(
            "REAL APP WINDOW: selected \(spec.name) \(metadata.id.description) pid=\(metadata.pid) new=\(createdByVerifier)"
        )
        return RealAppOriginal(
            spec: spec,
            bundleID: bundleID,
            metadata: metadata,
            frame: metadata.frame,
            createdByVerifier: createdByVerifier
        )
    }

    private static func verificationTitleSubstrings(for spec: RealAppSpec, token: String) -> [String] {
        switch spec.name {
        case "Terminal":
            return ["Narwhal Real App Verifier \(token)"]
        case "Google Chrome", "Firefox":
            return spec.preferredTitleSubstrings.map { "\($0) \(token)-" }
        default:
            return spec.preferredTitleSubstrings
        }
    }

    private static func closeUntrackedVerifierWindows(
        spec: RealAppSpec,
        bundleID: String,
        excluding excludedIDs: Set<WindowID>,
        using axClient: AXClient
    ) async {
        let candidates = windows(for: spec, bundleID: bundleID, using: axClient)
            .filter { !excludedIDs.contains($0.id) }
        for candidate in candidates {
            let original = RealAppOriginal(
                spec: spec,
                bundleID: bundleID,
                metadata: candidate,
                frame: candidate.frame,
                createdByVerifier: true
            )
            do {
                try await closeCreatedWindow(original, using: axClient)
                report("REAL APP WINDOW: cleaned failed launch \(spec.name) \(candidate.id.description)")
            } catch {
                report(
                    "REAL APP WINDOW: failed to clean launch \(spec.name) \(candidate.id.description): \(String(describing: error))"
                )
            }
        }
    }

    private static func cleanupApp(_ original: RealAppOriginal, using axClient: AXClient) async throws {
        if original.createdByVerifier {
            try await closeCreatedWindow(original, using: axClient)
            return
        }
        try await restoreWindow(
            original.metadata,
            bundleID: original.bundleID,
            appName: original.spec.name,
            to: original.frame,
            using: axClient
        )
    }

    private static func cleanupApps(_ originals: [RealAppOriginal], using axClient: AXClient) async throws {
        for original in originals.reversed() {
            try await cleanupApp(original, using: axClient)
        }
    }

    private static func cleanupAppsBestEffort(
        _ originals: [RealAppOriginal],
        using axClient: AXClient,
        context: String
    ) async {
        for original in originals.reversed() {
            do {
                try await cleanupApp(original, using: axClient)
            } catch {
                print(
                    "\(context): failed to clean up \(original.spec.name) window \(original.metadata.id.description): \(String(describing: error))"
                )
            }
        }
    }

    private static func launch(spec: RealAppSpec, bundleID: String, token: String) throws -> URL? {
        if spec.name == "Finder" {
            try FinderWindowOpener.openHomeWindow()
            return nil
        }
        if spec.name == "Terminal" {
            try launchTerminalVerificationWindow(token: token)
            return nil
        }
        if spec.name == "Google Chrome" {
            return try launchChromeVerificationWindow(token: token)
        }
        if spec.name == "Firefox" {
            return try launchFirefoxVerificationWindow(token: token)
        }
        let process = Process()
        if let launchExecutablePath = spec.launchExecutablePath {
            process.executableURL = URL(fileURLWithPath: launchExecutablePath)
            process.arguments = spec.launchArguments
        } else {
            var arguments = ["-a", spec.launchName]
            arguments.append(contentsOf: spec.launchArguments)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RealAppWindowVerifierFailure(
                "\(spec.name) launch failed with status \(process.terminationStatus)"
            )
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.activate(options: [.activateAllWindows])
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        return nil
    }

    private static func launchTerminalVerificationWindow(token: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            """
            tell application "Terminal"
                activate
                do script "printf '\\\\e]0;Narwhal Real App Verifier \(token)\\\\a'; echo Narwhal real-app verifier \(token)"
            end tell
            """
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RealAppWindowVerifierFailure("Terminal verification window launch failed with status \(process.terminationStatus)")
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal") {
            app.activate(options: [.activateAllWindows])
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
    }

    private static func waitForUsableWindow(
        spec: RealAppSpec,
        bundleID: String,
        using axClient: AXClient,
        excluding excludedIDs: Set<WindowID> = [],
        requiredTitleSubstrings: [String] = []
    ) async throws -> WindowMetadata {
        let deadline = Date().addingTimeInterval(14)
        var lastCandidates: [WindowMetadata] = []
        var lastSeen: [WindowMetadata] = []
        var lastIdentityFailure = ""
        while Date() < deadline {
            lastSeen = windows(for: spec, bundleID: bundleID, using: axClient)
                .sorted { $0.frame.area > $1.frame.area }
            lastCandidates = lastSeen
                .filter {
                    $0.isResizable
                        && !$0.isMinimized
                        && !excludedIDs.contains($0.id)
                        && $0.frame.width >= spec.minimumWindowSize.width
                        && $0.frame.height >= spec.minimumWindowSize.height
                }
                .sorted { $0.id.raw > $1.id.raw }
            if requiredTitleSubstrings.isEmpty, let candidate = lastCandidates.first {
                return candidate
            }
            for candidate in lastCandidates {
                switch await axClient.focusWindow(candidate) {
                case .success:
                    switch axClient.focusedWindowSnapshot() {
                    case .success(let focused)
                        where focused.id == candidate.id
                            && requiredTitleSubstrings.contains(where: {
                                focused.title.localizedCaseInsensitiveContains($0)
                            }):
                        return candidate
                    case .success(let focused):
                        lastIdentityFailure = "candidate=\(candidate.id.description) focused=\(focused.id.description) title=\"\(focused.title)\""
                    case .failure(let error):
                        lastIdentityFailure = "candidate=\(candidate.id.description) focused snapshot failed: \(error.description)"
                    }
                case .failure(let error):
                    lastIdentityFailure = "candidate=\(candidate.id.description) focus failed: \(error.description)"
                }
            }
            await settleLiveVerifier(for: 0.25)
        }

        let seen = lastCandidates
            .map { "\($0.id.description) \($0.frame.shortDescription) resizable=\($0.isResizable)" }
            .joined(separator: ", ")
        let allSeen = lastSeen
            .map { "\($0.id.description) \($0.frame.shortDescription) resizable=\($0.isResizable) minimized=\($0.isMinimized) title=\"\($0.title)\"" }
            .joined(separator: ", ")
        throw RealAppWindowVerifierFailure(
            "\(spec.name) did not expose a usable resizable AX window for bundle \(bundleID) with minimum size \(spec.minimumWindowSize.shortDescription); candidates=[\(seen)] allVisibleForBundle=[\(allSeen)] identity=[\(lastIdentityFailure)]"
        )
    }

    private static func verifyFrameWrite(
        _ target: CGRect,
        metadata: WindowMetadata,
        appName: String,
        step: Int,
        using axClient: AXClient
    ) async throws -> CGRect {
        let writer = WindowFrameWriter(axClient: axClient)
        let actual: CGRect
        switch await writer.setFrame(metadata, to: target) {
        case .converged(let frame):
            actual = frame
        case .constrained(let frame):
            actual = frame
        case .clamped(let frame, let observed):
            guard frameWriteApproximatelySettled(
                target: target,
                actual: frame,
                tolerance: Double(max(frameWriteSettleTolerance, Self.realAppFrameWriteTolerance))
            ) else {
                throw RealAppWindowVerifierFailure(
                    "\(appName) step \(step) clamped instead of settling: target=\(target.debugDescription) actual=\(frame.debugDescription) observed=\(observed)"
                )
            }
            actual = frame
        case .failed(.frameDidNotConverge(_, let frame, _))
            where frameWriteApproximatelySettled(
                target: target,
                actual: frame,
                tolerance: Double(max(frameWriteSettleTolerance, Self.realAppFrameWriteTolerance))
            ):
            actual = frame
        case .failed(let error):
            throw RealAppWindowVerifierFailure(
                "\(appName) step \(step) frame write failed: \(error.description)"
            )
        }

        guard frameWriteApproximatelySettled(
            target: target,
            actual: actual,
            tolerance: Double(max(frameWriteSettleTolerance, Self.realAppFrameWriteTolerance))
        ) else {
            throw RealAppWindowVerifierFailure(
                "\(appName) step \(step) did not settle near target: target=\(target.debugDescription) actual=\(actual.debugDescription)"
            )
        }

        let serverFrame = LiveWindowServerVerification.waitForFrame(
            windowNumber: Int(metadata.id.raw),
            matching: actual,
            tolerance: frameWriteSettleTolerance
        )
        guard serverFrame?.matches(actual, tolerance: frameWriteSettleTolerance) == true else {
            throw RealAppWindowVerifierFailure(
                "\(appName) step \(step) WindowServer did not show actual frame: expected=\(actual.debugDescription) actual=\(serverFrame?.debugDescription ?? "nil")"
            )
        }

        return actual
    }

    private static func closeCreatedWindow(_ original: RealAppOriginal, using axClient: AXClient) async throws {
        if original.spec.name == "Terminal",
           closeTerminalWindow(windowID: original.metadata.id) {
            if await waitForWindowServerRemoval(original.metadata.id) {
                report("REAL APP WINDOW: closed Terminal \(original.metadata.id.description)")
                return
            }
        }

        switch await axClient.closeWindow(original.metadata) {
        case .success:
            guard await waitForWindowServerRemoval(original.metadata.id) else {
                throw RealAppWindowVerifierFailure(
                    "\(original.spec.name) close request left verifier-created window \(original.metadata.id.description) visible"
                )
            }
            report("REAL APP WINDOW: closed \(original.spec.name) \(original.metadata.id.description)")
            return
        case .failure(let error):
            throw RealAppWindowVerifierFailure(
                "\(original.spec.name) could not close verifier-created window \(original.metadata.id.description): \(error.description)"
            )
        }
    }

    private static func waitForWindowServerRemoval(_ windowID: WindowID) async -> Bool {
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            if LiveWindowServerVerification.frame(for: Int(windowID.raw)) == nil {
                return true
            }
            await settleLiveVerifier(for: 0.05)
        }
        return false
    }

    private static func report(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private static func closeTerminalWindow(windowID: WindowID) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            """
            tell application "Terminal"
                if exists window id \(windowID.raw) then
                    try
                        do script "exit" in selected tab of window id \(windowID.raw)
                    end try
                    delay 0.1
                    try
                        close (window id \(windowID.raw)) saving no
                    end try
                end if
            end tell
            """
        ]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func restoreWindow(
        _ original: WindowMetadata,
        bundleID: String,
        appName: String,
        to frame: CGRect,
        using axClient: AXClient
    ) async throws {
        var failures: [String] = []
        switch await axClient.setFrame(original, to: frame) {
        case .converged, .constrained, .clamped:
            return
        case .failed(let error):
            failures.append("original=\(error.description)")
        }

        let candidates = axClient.windowSnapshot().windows
            .filter { $0.bundleID.raw == bundleID && $0.isResizable && !$0.isMinimized }
            .sorted {
                if $0.id == original.id { return true }
                if $1.id == original.id { return false }
                return $0.frame.area > $1.frame.area
            }
        for candidate in candidates {
            switch await axClient.setFrame(candidate, to: frame) {
            case .converged, .constrained, .clamped:
                return
            case .failed(let error):
                failures.append("\(candidate.id.description)=\(error.description)")
            }
        }

        throw RealAppWindowVerifierFailure(
            "\(appName) could not restore window to \(frame.debugDescription): \(failures.joined(separator: "; "))"
        )
    }

    private static func targetFrames(
        in visibleFrame: CGRect,
        originalFrame: CGRect,
        spec: RealAppSpec
    ) throws -> [CGRect] {
        let maxFirstWidth = max(spec.minimumWindowSize.width, visibleFrame.width - 96)
        let maxSecondWidth = max(spec.minimumWindowSize.width, visibleFrame.width - 120)
        let maxFirstHeight = max(spec.minimumWindowSize.height, visibleFrame.height - 96)
        let maxSecondHeight = max(spec.minimumWindowSize.height, visibleFrame.height - 120)
        let firstWidth: CGFloat
        let firstHeight: CGFloat
        let secondWidth: CGFloat
        let secondHeight: CGFloat
        switch spec.name {
        case "Firefox":
            firstWidth = min(max(visibleFrame.width * 0.80, spec.minimumWindowSize.width + 950), maxFirstWidth)
            firstHeight = min(max(visibleFrame.height * 0.44, spec.minimumWindowSize.height + 620), maxFirstHeight)
            secondWidth = min(max(visibleFrame.width * 0.76, spec.minimumWindowSize.width + 900), maxSecondWidth)
            secondHeight = min(max(visibleFrame.height * 0.40, spec.minimumWindowSize.height + 560), maxSecondHeight)
        case "System Settings":
            firstWidth = max(Self.systemSettingsStableAXWidth, originalFrame.width)
            firstHeight = min(max(visibleFrame.height * 0.60, spec.minimumWindowSize.height + 260), maxFirstHeight)
            secondWidth = firstWidth
            secondHeight = min(max(visibleFrame.height * 0.54, spec.minimumWindowSize.height + 220), maxSecondHeight)
        default:
            firstWidth = min(max(visibleFrame.width * 0.62, spec.minimumWindowSize.width + 360), maxFirstWidth)
            firstHeight = min(max(visibleFrame.height * 0.50, spec.minimumWindowSize.height + 420), maxFirstHeight)
            secondWidth = min(max(visibleFrame.width * 0.56, spec.minimumWindowSize.width + 320), maxSecondWidth)
            secondHeight = min(max(visibleFrame.height * 0.44, spec.minimumWindowSize.height + 360), maxSecondHeight)
        }
        guard firstWidth >= spec.minimumWindowSize.width,
              firstHeight >= spec.minimumWindowSize.height,
              secondWidth >= spec.minimumWindowSize.width,
              secondHeight >= spec.minimumWindowSize.height
        else {
            throw RealAppWindowVerifierFailure(
                "\(spec.name) could not construct non-clamping real-app frame targets: original=\(originalFrame.debugDescription) visible=\(visibleFrame.debugDescription) minimum=\(spec.minimumWindowSize.shortDescription)"
            )
        }
        return [
            CGRect(
                x: visibleFrame.minX + 40,
                y: visibleFrame.minY + 44,
                width: firstWidth,
                height: firstHeight
            ).standardized,
            CGRect(
                x: visibleFrame.maxX - secondWidth - 56,
                y: visibleFrame.minY + 86,
                width: secondWidth,
                height: secondHeight
            ).standardized
        ]
    }

    private static func normalizeFreshBrowserWindow(
        _ metadata: WindowMetadata,
        appName: String,
        in visibleFrame: CGRect,
        using axClient: AXClient
    ) async throws {
        let writer = WindowFrameWriter(axClient: axClient)
        let target = CGRect(
            x: visibleFrame.minX + 96,
            y: visibleFrame.minY + 96,
            width: max(640, visibleFrame.width * 0.58),
            height: max(480, visibleFrame.height * 0.58)
        ).intersection(visibleFrame)
        let actual: CGRect
        switch await writer.setFrame(metadata, to: target) {
        case .converged(let frame), .constrained(let frame), .clamped(let frame, _):
            actual = frame
        case .failed(.frameDidNotConverge(_, let frame, _)) where frame.narwhalIsFinitePositive:
            actual = frame
        case .failed(let error):
            throw RealAppWindowVerifierFailure(
                "\(appName) could not leave its fresh-window state before verification: \(error.description)"
            )
        }
        report(
            "REAL APP WINDOW: normalized \(appName) target=\(target.debugDescription) "
                + "actual=\(actual.debugDescription)"
        )
        guard visibleFrame.intersection(actual).narwhalArea >= actual.narwhalArea * 0.9 else {
            throw RealAppWindowVerifierFailure(
                "\(appName) browser normalization left the window off display: actual=\(actual.debugDescription) visible=\(visibleFrame.debugDescription)"
            )
        }
        let serverFrame = LiveWindowServerVerification.waitForFrame(
            windowNumber: Int(metadata.id.raw),
            matching: actual,
            tolerance: frameWriteSettleTolerance
        )
        guard serverFrame?.matches(actual, tolerance: frameWriteSettleTolerance) == true else {
            throw RealAppWindowVerifierFailure(
                "\(appName) browser normalization was not visible in WindowServer: AX=\(actual.debugDescription) WindowServer=\(serverFrame?.debugDescription ?? "nil")"
            )
        }
        await settleLiveVerifier(for: 0.35)
    }

    private static func displayContaining(
        _ frame: CGRect,
        displays: [DisplayID: DisplayInfo]
    ) -> DisplayInfo? {
        guard let displayID = displayContainingFrame(frame, displays: displays) else { return nil }
        return displays[displayID]
    }
}

struct RealAppSpec {
    let name: String
    let bundleIDs: [String]
    let launchName: String
    let launchExecutablePath: String?
    let launchArguments: [String]
    let minimumWindowSize: CGSize
    let required: Bool
    let pattern: RealAppPattern
    let workflowDirections: [Direction]
    let preferredTitleSubstrings: [String]
}

struct RealAppOriginal {
    let spec: RealAppSpec
    let bundleID: String
    let metadata: WindowMetadata
    let frame: CGRect
    let createdByVerifier: Bool
}

enum RealAppPattern {
    case browser
    case terminal
    case system
    case productivity
}

private func finderSpec() -> RealAppSpec {
    RealAppSpec(
        name: "Finder",
        bundleIDs: ["com.apple.finder"],
        launchName: "Finder",
        launchExecutablePath: nil,
        launchArguments: [FileManager.default.homeDirectoryForCurrentUser.path],
        minimumWindowSize: CGSize(width: 420, height: 320),
        required: true,
        pattern: .system,
        workflowDirections: Direction.allCases,
        preferredTitleSubstrings: []
    )
}

private func safariSpec() -> RealAppSpec {
    RealAppSpec(
        name: "Safari",
        bundleIDs: ["com.apple.Safari"],
        launchName: "Safari",
        launchExecutablePath: nil,
        launchArguments: ["https://example.com/?narwhal-real-app=safari"],
        minimumWindowSize: CGSize(width: 420, height: 320),
        required: true,
        pattern: .browser,
        workflowDirections: Direction.allCases,
        preferredTitleSubstrings: ["Example Domain"]
    )
}

func terminalSpec() -> RealAppSpec {
    RealAppSpec(
        name: "Terminal",
        bundleIDs: ["com.apple.Terminal"],
        launchName: "Terminal",
        launchExecutablePath: nil,
        launchArguments: [],
        minimumWindowSize: CGSize(width: 300, height: 180),
        required: true,
        pattern: .terminal,
        workflowDirections: Direction.allCases,
        preferredTitleSubstrings: []
    )
}

private func systemSettingsSpec() -> RealAppSpec {
    RealAppSpec(
        name: "System Settings",
        bundleIDs: ["com.apple.SystemSettings", "com.apple.systempreferences"],
        launchName: "System Settings",
        launchExecutablePath: nil,
        launchArguments: [],
        minimumWindowSize: CGSize(width: 420, height: 320),
        required: true,
        pattern: .system,
        workflowDirections: [.left, .right],
        preferredTitleSubstrings: []
    )
}

private func chromeSpec() -> RealAppSpec {
    RealAppSpec(
        name: "Google Chrome",
        bundleIDs: ["com.google.Chrome"],
        launchName: "Google Chrome",
        launchExecutablePath: nil,
        launchArguments: ["--new-window", "https://example.com/?narwhal-real-app=chrome"],
        minimumWindowSize: CGSize(width: 420, height: 320),
        required: false,
        pattern: .browser,
        workflowDirections: [.up, .down],
        preferredTitleSubstrings: ["Narwhal Chrome Verifier"]
    )
}

private func firefoxSpec() -> RealAppSpec {
    RealAppSpec(
        name: "Firefox",
        bundleIDs: ["org.mozilla.firefox"],
        launchName: "Firefox",
        launchExecutablePath: "/Applications/Firefox.app/Contents/MacOS/firefox",
        launchArguments: ["--new-window", "https://example.com/?narwhal-real-app=firefox"],
        minimumWindowSize: CGSize(width: 300, height: 120),
        required: false,
        pattern: .browser,
        workflowDirections: Direction.allCases,
        preferredTitleSubstrings: ["Narwhal Firefox Verifier"]
    )
}

private func kittySpec() -> RealAppSpec {
    RealAppSpec(
        name: "kitty",
        bundleIDs: ["net.kovidgoyal.kitty"],
        launchName: "kitty",
        launchExecutablePath: nil,
        launchArguments: [],
        minimumWindowSize: CGSize(width: 300, height: 180),
        required: false,
        pattern: .terminal,
        workflowDirections: Direction.allCases,
        preferredTitleSubstrings: []
    )
}

private func dockerSpec() -> RealAppSpec {
    RealAppSpec(
        name: "Docker Desktop",
        bundleIDs: ["com.docker.docker"],
        launchName: "Docker",
        launchExecutablePath: nil,
        launchArguments: [],
        minimumWindowSize: CGSize(width: 420, height: 320),
        required: false,
        pattern: .productivity,
        workflowDirections: [.left, .right],
        preferredTitleSubstrings: []
    )
}

private func teamsSpec() -> RealAppSpec {
    RealAppSpec(
        name: "Microsoft Teams",
        bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
        launchName: "Microsoft Teams",
        launchExecutablePath: nil,
        launchArguments: [],
        minimumWindowSize: CGSize(width: 420, height: 320),
        required: false,
        pattern: .productivity,
        workflowDirections: [.left, .right],
        preferredTitleSubstrings: []
    )
}

private func outlookSpec() -> RealAppSpec {
    RealAppSpec(
        name: "Microsoft Outlook",
        bundleIDs: ["com.microsoft.Outlook"],
        launchName: "Microsoft Outlook",
        launchExecutablePath: nil,
        launchArguments: [],
        minimumWindowSize: CGSize(width: 420, height: 320),
        required: false,
        pattern: .productivity,
        workflowDirections: [.left, .right],
        preferredTitleSubstrings: []
    )
}

private func notionSpec() -> RealAppSpec {
    RealAppSpec(
        name: "Notion",
        bundleIDs: ["notion.id"],
        launchName: "Notion",
        launchExecutablePath: nil,
        launchArguments: [],
        minimumWindowSize: CGSize(width: 420, height: 320),
        required: false,
        pattern: .productivity,
        workflowDirections: [.left, .right],
        preferredTitleSubstrings: []
    )
}

private func whatsAppSpec() -> RealAppSpec {
    RealAppSpec(
        name: "WhatsApp",
        bundleIDs: ["net.whatsapp.WhatsApp"],
        launchName: "WhatsApp",
        launchExecutablePath: nil,
        launchArguments: [],
        minimumWindowSize: CGSize(width: 420, height: 320),
        required: false,
        pattern: .productivity,
        workflowDirections: [.left, .right],
        preferredTitleSubstrings: []
    )
}

private func commonWorkflowSpecs() -> [RealAppSpec] {
    [
        terminalSpec(),
        chromeSpec(),
        firefoxSpec()
    ]
}

struct RealAppWindowVerifierFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = "real app window verification failed: \(message)"
    }
}

private extension CGRect {
    var area: CGFloat {
        narwhalArea
    }

    var shortDescription: String {
        "(\(Int(minX)),\(Int(minY)),\(Int(width)),\(Int(height)))"
    }

    func matches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        narwhalApproximatelyEquals(other, tolerance: tolerance)
    }
}

private extension CGSize {
    var shortDescription: String {
        "(\(Int(width)),\(Int(height)))"
    }
}

#endif
