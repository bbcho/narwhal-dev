#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import CoreGraphics
import Foundation
import NarwhalAppSupport
import NarwhalCore
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
    func firefoxAcceptsRealAXFrameWrites() throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(RealAppWindowVerification.verifyFirefox())
    }

    @Test("Chrome accepts real AX frame writes")
    func chromeAcceptsRealAXFrameWrites() throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(RealAppWindowVerification.verifyChrome())
    }

    @Test("System Settings accepts real AX frame writes")
    func systemSettingsAcceptsRealAXFrameWrites() throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(RealAppWindowVerification.verifySystemSettings())
    }

    @Test("Real apps complete Narwhal command workflows")
    func realAppsCompleteNarwhalCommandWorkflows() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifyRealAppCommandWorkflows())
    }

    @Test("Chrome and Firefox complete real manual tile resize")
    func chromeAndFirefoxCompleteRealManualTileResize() async throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(await RealAppWindowVerification.verifyChromeFirefoxManualTileResize())
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
    private static let browserResizeReserveDelta = 0.18

    static func verifyFirefox() -> (passed: Bool, message: String) {
        verifyApp(firefoxSpec())
    }

    static func verifyChrome() -> (passed: Bool, message: String) {
        verifyApp(chromeSpec())
    }

    static func verifySystemSettings() -> (passed: Bool, message: String) {
        verifyApp(systemSettingsSpec())
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
        do {
            try waitForUnlockedSession()
            let displays = DisplayClient().currentDisplays()
            guard displays.values.contains(where: { $0.visibleFrame.width >= 900 && $0.visibleFrame.height >= 620 }) else {
                throw RealAppWindowVerifierFailure("manual browser resize verification requires a display at least 900x620")
            }

            let axClient = AXClient(processID: -1)
            var originals: [RealAppOriginal] = []
            var didRestore = false
            defer {
                if !didRestore {
                    for original in originals.reversed() {
                        do {
                            try cleanupApp(original, using: axClient)
                        } catch {
                            print("REAL APP MANUAL RESIZE VERIFY: failed to clean up \(original.spec.name) window \(original.metadata.id.description): \(String(describing: error))")
                        }
                    }
                }
            }

            for spec in [chromeSpec(), firefoxSpec(), terminalSpec()] {
                let bundleID = try installedBundleID(for: spec)
                let wasRunning = isRunning(bundleID: bundleID)
                let excludedIDs = preexistingBrowserWindowIDs(for: spec, bundleID: bundleID, using: axClient)
                if spec.name == "Google Chrome" {
                    try launchChromeVerificationWindow(token: "manual")
                } else {
                    try launch(spec: spec, bundleID: bundleID)
                }
                let metadata = try waitForUsableWindow(
                    spec: spec,
                    bundleID: bundleID,
                    using: axClient,
                    excluding: excludedIDs
                )
                originals.append(RealAppOriginal(
                    spec: spec,
                    bundleID: bundleID,
                    metadata: metadata,
                    frame: metadata.frame,
                    wasRunningBeforeTest: wasRunning
                ))
            }

            let targetDisplay = try manualResizeVerificationDisplay(displays)
            try await stageManualResizeWindows(
                originals,
                on: targetDisplay,
                using: axClient
            )

            let summary = try await verifyChromeFirefoxManualResizeWorkflow(
                originals,
                targetDisplay: targetDisplay,
                axClient: axClient,
                displays: displays
            )

            for original in originals.reversed() {
                try cleanupApp(original, using: axClient)
            }
            didRestore = true
            return (true, summary)
        } catch let error as RealAppWindowVerifierFailure {
            return (false, error.message)
        } catch {
            return (false, "manual browser resize verification failed: \(String(describing: error))")
        }
    }

    static func verifyThreeFirefoxVerticalStack() async -> (passed: Bool, message: String) {
        await verifyThreeWindowVerticalStack(spec: firefoxSpec(), label: "Firefox")
    }

    static func verifyThreeChromeVerticalStack() async -> (passed: Bool, message: String) {
        await verifyThreeWindowVerticalStack(spec: chromeSpec(), label: "Google Chrome")
    }

    private static func verifyThreeWindowVerticalStack(
        spec: RealAppSpec,
        label: String
    ) async -> (passed: Bool, message: String) {
        do {
            try waitForUnlockedSession()
            let displays = DisplayClient().currentDisplays()
            let targetDisplay = try manualResizeVerificationDisplay(displays)
            let axClient = AXClient(processID: -1)
            let bundleID = try installedBundleID(for: spec)
            let wasRunning = isRunning(bundleID: bundleID)
            var originals: [RealAppOriginal] = []
            var selectedIDs = Set<WindowID>()
            var didRestore = false
            defer {
                if !didRestore {
                    for original in originals.reversed() {
                        do {
                            try cleanupApp(original, using: axClient)
                        } catch {
                            print("REAL \(label.uppercased()) STACK VERIFY: failed to clean up \(original.metadata.id.description): \(String(describing: error))")
                        }
                    }
                }
            }

            for index in 0..<3 {
                if spec.name == "Google Chrome" {
                    try launchChromeVerificationWindow(token: "stack-\(index)")
                } else {
                    try launch(spec: spec, bundleID: bundleID)
                }
                let metadata = try waitForUsableWindow(
                    spec: spec,
                    bundleID: bundleID,
                    using: axClient,
                    excluding: selectedIDs
                )
                selectedIDs.insert(metadata.id)
                originals.append(RealAppOriginal(
                    spec: spec,
                    bundleID: bundleID,
                    metadata: metadata,
                    frame: metadata.frame,
                    wasRunningBeforeTest: wasRunning
                ))
            }

            let frames = try threeWindowVerticalStackFrames(in: targetDisplay.visibleFrame)
            var actuals: [CGRect] = []
            for (index, original) in originals.enumerated() {
                let metadata = try currentWorkflowMetadata(for: original, using: axClient)
                try await focusIfPossible(metadata, appName: "\(label) stack \(index + 1)", using: axClient)
                let actual = try verifyFrameWrite(
                    frames[index],
                    metadata: metadata,
                    appName: "\(label) vertical stack",
                    step: index + 1,
                    using: axClient
                )
                try requireFrame(actual, isOn: targetDisplay, context: "\(label) vertical stack \(index + 1)")
                actuals.append(actual)
            }

            for first in actuals.indices {
                for second in actuals.indices where second > first {
                    guard framesDoNotVisiblyOverlap(actuals[first], actuals[second], tolerance: frameWriteSettleTolerance) else {
                        throw RealAppWindowVerifierFailure(
                            "\(label) vertical stack windows overlapped: first=\(actuals[first].debugDescription) second=\(actuals[second].debugDescription)"
                        )
                    }
                }
            }

            for original in originals.reversed() {
                try cleanupApp(original, using: axClient)
            }
            didRestore = true

            return (true, "three \(label) vertical stack passed: \(actuals.map(\.shortDescription).joined(separator: ","))")
        } catch let error as RealAppWindowVerifierFailure {
            return (false, error.message)
        } catch {
            return (false, "three \(label) vertical stack verification failed: \(String(describing: error))")
        }
    }

    private static func launchChromeVerificationWindow(token: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let url = "https://example.com/?narwhal-real-app=chrome-\(token)"
        process.arguments = [
            "-n",
            "-a", "Google Chrome",
            "--args",
            "--new-window",
            url
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RealAppWindowVerifierFailure("Google Chrome new-window launch failed with status \(process.terminationStatus)")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
    }

    private static func verifyApp(_ spec: RealAppSpec) -> (passed: Bool, message: String) {
        do {
            try waitForUnlockedSession()
            let displays = DisplayClient().currentDisplays()
            guard !displays.isEmpty else {
                throw RealAppWindowVerifierFailure("no displays available")
            }
            guard displays.values.contains(where: { $0.visibleFrame.width >= 900 && $0.visibleFrame.height >= 620 }) else {
                throw RealAppWindowVerifierFailure("real app verification requires a display at least 900x620")
            }

            return (true, "real app frame verification passed: \(try verify(spec: spec, displays: displays))")
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
    ) throws -> String {
        let bundleID = try installedBundleID(for: spec)
        let wasRunning = isRunning(bundleID: bundleID)
        let axClient = AXClient(processID: -1)
        let excludedIDs = preexistingBrowserWindowIDs(for: spec, bundleID: bundleID, using: axClient)
        if spec.name == "Google Chrome" {
            try launchChromeVerificationWindow(token: "direct")
        } else {
            try launch(spec: spec, bundleID: bundleID)
        }

        let original = try waitForUsableWindow(
            spec: spec,
            bundleID: bundleID,
            using: axClient,
            excluding: excludedIDs
        )
        let restoreFrame = original.frame
        var didRestore = false
        defer {
            if !didRestore {
                do {
                    try cleanupApp(
                        RealAppOriginal(
                            spec: spec,
                            bundleID: bundleID,
                            metadata: original,
                            frame: restoreFrame,
                            wasRunningBeforeTest: wasRunning
                        ),
                        using: axClient
                    )
                } catch {
                    print("REAL APP VERIFY: failed to clean up \(spec.name) window \(original.id.description): \(String(describing: error))")
                }
            }
        }

        switch axClient.focusWindow(original) {
        case .success:
            break
        case .failure(let error):
            print("REAL APP VERIFY: \(spec.name) focus was unavailable before frame writes: \(error.description)")
        }

        let display = displayContaining(original.frame, displays: displays)
            ?? displays.values.sorted(by: { $0.slot < $1.slot }).first!
        let targets = try targetFrames(in: display.visibleFrame, originalFrame: original.frame, spec: spec)
        var actuals: [CGRect] = []

        for (index, target) in targets.enumerated() {
            let actual = try verifyFrameWrite(
                target,
                metadata: original,
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

        try cleanupApp(
            RealAppOriginal(
                spec: spec,
                bundleID: bundleID,
                metadata: original,
                frame: restoreFrame,
                wasRunningBeforeTest: wasRunning
            ),
            using: axClient
        )
        didRestore = true

        return "\(spec.name)=\(actuals.map(\.shortDescription).joined(separator: ","))"
    }

    private static func verifyRealCommandWorkflows(displays: [DisplayID: DisplayInfo]) async throws -> String {
        let specs = commonWorkflowSpecs()
        let axClient = AXClient(processID: -1)
        var originals: [RealAppOriginal] = []
        var skipped: [String] = []
        var didRestore = false
        defer {
            if !didRestore {
                for original in originals.reversed() {
                    do {
                        try cleanupApp(original, using: axClient)
                    } catch {
                        print("REAL APP WORKFLOW VERIFY: failed to clean up \(original.spec.name) window \(original.metadata.id.description): \(String(describing: error))")
                    }
                }
            }
        }

        for spec in specs {
            let bundleID: String
            do {
                bundleID = try installedBundleID(for: spec)
            } catch {
                if spec.required {
                    throw error
                }
                skipped.append(spec.name)
                continue
            }
            let wasRunning = isRunning(bundleID: bundleID)
            let excludedIDs = preexistingBrowserWindowIDs(for: spec, bundleID: bundleID, using: axClient)
            if spec.name == "Google Chrome" {
                try launchChromeVerificationWindow(token: "workflow")
            } else {
                try launch(spec: spec, bundleID: bundleID)
            }
            let metadata: WindowMetadata
            do {
                metadata = try waitForUsableWindow(
                    spec: spec,
                    bundleID: bundleID,
                    using: axClient,
                    excluding: excludedIDs
                )
            } catch {
                if !wasRunning {
                    quitApp(bundleID: bundleID, appName: spec.name)
                }
                if spec.required || spec.pattern == .browser || spec.pattern == .terminal {
                    throw error
                }
                skipped.append("\(spec.name): no standard AX window")
                continue
            }
            originals.append(RealAppOriginal(
                spec: spec,
                bundleID: bundleID,
                metadata: metadata,
                frame: metadata.frame,
                wasRunningBeforeTest: wasRunning
            ))
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

        for original in originals.reversed() {
            try cleanupApp(original, using: axClient)
        }
        didRestore = true

        return "\(summaries.joined(separator: "; ")) skipped=\(skipped.isEmpty ? "none" : skipped.joined(separator: ","))"
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
        try await applyFirstSuccessfulWorkflowCommand(
            "mixed \(resizeTarget.spec.name) resize split",
            plans: Direction.allCases.map { direction in
                (
                    name: "mixed \(resizeTarget.spec.name) resize \(direction.rawValue)",
                    plan: { await worldActor.planResize(currentResizeTarget.id, direction: direction, delta: 0.10) }
                )
            },
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
        let resizePlannedFrames = try await applyWorkflowCommand(
            "Chrome over Firefox Chrome resize down",
            plan: { await worldActor.planResize(chromeBefore.id, direction: .down, delta: 0.10) },
            worldActor: worldActor,
            applier: applier
        )

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

        return "chrome-over-firefox resize chrome=\(chromeAfter.frame.shortDescription) firefox=\(firefoxAfter.frame.shortDescription)"
    }

    private static func verifyChromeFirefoxManualResizeWorkflow(
        _ originals: [RealAppOriginal],
        targetDisplay: DisplayInfo,
        axClient: AXClient,
        displays: [DisplayID: DisplayInfo]
    ) async throws -> String {
        let chrome = try requireOriginal(named: "Google Chrome", in: originals)
        let firefox = try requireOriginal(named: "Firefox", in: originals)
        let companion = try requireOriginal(named: "Terminal", in: originals)
        let worldActor = WorldActor(config: .default)
        let reporter = StartupReporter(logPath: "/tmp/narwhal-real-app-manual-resize.log")
        let applier = LayoutApplier(axClient: axClient, reporter: reporter)

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        let companionWindow = try currentWorkflowMetadata(for: companion, using: axClient)
        try await focusIfPossible(companionWindow, appName: companion.spec.name, using: axClient)
        try await applyWorkflowCommand(
            "manual browser resize companion push right",
            plan: { await worldActor.planPush(companionWindow.id, direction: .right) },
            worldActor: worldActor,
            applier: applier
        )

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        let chromeWindow = try currentWorkflowMetadata(for: chrome, using: axClient)
        try await focusIfPossible(chromeWindow, appName: chrome.spec.name, using: axClient)
        try await applyWorkflowCommand(
            "manual browser resize Chrome push left",
            plan: { await worldActor.planPush(chromeWindow.id, direction: .left) },
            worldActor: worldActor,
            applier: applier
        )

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
        let firefoxWindow = try currentWorkflowMetadata(for: firefox, using: axClient)
        try await focusIfPossible(firefoxWindow, appName: firefox.spec.name, using: axClient)
        try await applyWorkflowCommand(
            "manual browser resize Firefox push left",
            plan: { await worldActor.planPush(firefoxWindow.id, direction: .left) },
            worldActor: worldActor,
            applier: applier
        )

        try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
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
        for attempt in 1...4 {
            if firefoxAfterReserve.frame.height - firefoxBefore.frame.height >= 56 {
                break
            }
            try await focusIfPossible(firefoxAfterReserve, appName: firefox.spec.name, using: axClient)
            try await applyWorkflowCommand(
                "manual browser resize Firefox reserve shrink room \(attempt)",
                plan: { await worldActor.planResize(firefoxAfterReserve.id, direction: .up, delta: 0.35) },
                worldActor: worldActor,
                applier: applier
            )

            try await refreshWorkflowWorld(worldActor, axClient: axClient, displays: displays)
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

        let manualChromeFrame: CGRect
        switch axClient.setFrame(chromeAfterReserve, to: requestedChromeFrame) {
        case .converged(let frame):
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

        let event: AXEvent
        if manualChromeFrame.matches(
            CGRect(origin: chromeAfterReserve.frame.origin, size: manualChromeFrame.size),
            tolerance: 2
        ) {
            event = .windowResized(chromeAfterReserve.id, manualChromeFrame.size)
        } else {
            event = .windowMoved(chromeAfterReserve.id, manualChromeFrame)
        }
        let externalPlannedFrames = try await applyExternalGeometryWorkflowEvent(
            "manual browser resize Chrome external geometry",
            event: event,
            worldActor: worldActor,
            applier: applier
        )

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
            )
        else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize left companion overlapping browser stack: "
                    + "companion=\(companionAfter.frame.debugDescription) "
                    + "chrome=\(chromeAfter.frame.debugDescription) "
                    + "firefox=\(firefoxAfter.frame.debugDescription)"
            )
        }

        return "real 3-window Chrome/Firefox manual resize companion=\(companionAfter.frame.shortDescription) chrome=\(chromeAfter.frame.shortDescription) firefox=\(firefoxAfter.frame.shortDescription)"
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

    private static func stageManualResizeWindows(
        _ originals: [RealAppOriginal],
        on display: DisplayInfo,
        using axClient: AXClient
    ) async throws {
        let chrome = try requireOriginal(named: "Google Chrome", in: originals)
        let firefox = try requireOriginal(named: "Firefox", in: originals)
        let companion = try requireOriginal(named: "Terminal", in: originals)
        let visible = display.visibleFrame
        let margin: CGFloat = 40
        let stackGap: CGFloat = 40
        let browserWidth = min(max(visible.width * 0.45, 1_300), visible.width * 0.48)
        let stackHeight = visible.height - margin * 2 - stackGap
        let minimumChromeHeight: CGFloat = 420
        let firefoxHeightWithShrinkRoom = Self.firefoxManualStagingMinimumHeight + Self.manualResizeShrinkReserve
        let chromeHeight = max(
            minimumChromeHeight,
            min(visible.height * 0.34, stackHeight - firefoxHeightWithShrinkRoom)
        )
        let firefoxHeight = stackHeight - chromeHeight
        guard chromeHeight >= minimumChromeHeight,
              firefoxHeight >= firefoxHeightWithShrinkRoom
        else {
            throw RealAppWindowVerifierFailure(
                "manual browser resize staging requires enough vertical room for Firefox shrink reserve: visible=\(visible.debugDescription)"
            )
        }
        let companionWidth = max(480, visible.width - browserWidth - margin * 3)
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
            _ = try verifyFrameWrite(
                placement.1,
                metadata: metadata,
                appName: "\(placement.0.spec.name) manual-resize staging",
                step: index + 1,
                using: axClient
            )
        }
        try? await Task.sleep(nanoseconds: 160_000_000)
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
        guard frame.matches(plannedFrame, tolerance: frameWriteSettleTolerance) else {
            throw RealAppWindowVerifierFailure(
                "\(context) did not match planned frame: "
                    + "expected=\(plannedFrame.debugDescription) "
                    + "actual=\(frame.debugDescription)"
            )
        }
        return plannedFrame
    }

    private static func refreshWorkflowWorld(
        _ worldActor: WorldActor,
        axClient: AXClient,
        displays: [DisplayID: DisplayInfo]
    ) async throws {
        let axSnapshot = axClient.windowSnapshot()
        guard axSnapshot.quality == .complete else {
            throw RealAppWindowVerifierFailure("real workflow AX snapshot was not complete: \(axSnapshot.quality)")
        }
        let spaceClient = SpaceClient()
        let topology = spaceClient.spaceTopology(displays: displays, windows: axSnapshot.windows)
        let activeSpace: SpaceID?
        switch spaceClient.activeSpaceID() {
        case .success(let spaceID):
            activeSpace = spaceID
        case .failure:
            activeSpace = topology.primaryActiveSpace
        }
        _ = await worldActor.refreshEnvironment(EnvironmentSnapshot(
            activeSpace: activeSpace,
            displays: displays,
            axSnapshot: axSnapshot,
            spaceTopology: topology,
            preserveSpaceLayouts: true,
            reconciliationMode: .observeOnly
        ))
    }

    @discardableResult
    private static func applyWorkflowCommand(
        _ name: String,
        plan: () async -> Result<CommandPlanResult, CommandError>,
        worldActor: WorldActor,
        applier: LayoutApplier,
        allowNoMove: Bool = false
    ) async throws -> [WindowID: CGRect] {
        let first = try await requireWorkflowPlan(name, plan(), allowNoMove: allowNoMove)
        if first.desiredLayout.delta.moves.isEmpty {
            await worldActor.commit(first, appliedFrames: [:])
            return first.desiredLayout.layout.tiled
        }
        let firstResult = applier.apply(first)
        switch plannedLayoutApplyDecision(plan: first, applyResult: firstResult, retryOnClamp: true) {
        case .commit(let appliedFrames, _):
            await worldActor.commit(first, appliedFrames: appliedFrames)
            try requireAppliedFramesVisible(appliedFrames, plan: first, context: name)
            return first.desiredLayout.layout.tiled

        case .fail(_, let failureCount, let summary):
            throw RealAppWindowVerifierFailure("\(name) failed applying \(failureCount) real app window(s): \(summary)")

        case .clamp(let appliedFrames, let observedConstraints, let shouldRetry, let summary):
            await worldActor.recordAppliedFrames(appliedFrames)
            await worldActor.recordObservedConstraints(observedConstraints)
            guard shouldRetry else {
                throw RealAppWindowVerifierFailure("\(name) clamped without retry: \(summary)")
            }
            let retry = try await requireWorkflowPlan("\(name) retry after clamp", plan(), allowNoMove: allowNoMove)
            let retryResult = applier.apply(retry)
            switch plannedLayoutApplyDecision(plan: retry, applyResult: retryResult, retryOnClamp: false) {
            case .commit(let retryAppliedFrames, _):
                await worldActor.commit(retry, appliedFrames: retryAppliedFrames)
                try requireAppliedFramesVisible(
                    retryAppliedFrames,
                    plan: retry,
                    context: "\(name) retry after clamp"
                )
                return retry.desiredLayout.layout.tiled
            case .fail(_, let failureCount, let retrySummary):
                throw RealAppWindowVerifierFailure(
                    "\(name) failed after clamp retry applying \(failureCount) real app window(s): initial=\(summary); retry=\(retrySummary)"
                )
            case .clamp(_, _, _, let retrySummary):
                throw RealAppWindowVerifierFailure("\(name) still clamped after retry: initial=\(summary); retry=\(retrySummary)")
            }
        }
    }

    private static func applyExternalGeometryWorkflowEvent(
        _ name: String,
        event: AXEvent,
        worldActor: WorldActor,
        applier: LayoutApplier
    ) async throws -> [WindowID: CGRect] {
        let first: CommandPlanResult
        switch await worldActor.planExternalGeometry(event) {
        case .success(let plan?):
            first = plan
        case .success(nil):
            throw RealAppWindowVerifierFailure("\(name) produced no sibling layout plan")
        case .failure(let error):
            throw RealAppWindowVerifierFailure("\(name) plan failed: \(error.message)")
        }

        let firstResult = applier.apply(first)
        switch plannedLayoutApplyDecision(plan: first, applyResult: firstResult, retryOnClamp: true) {
        case .commit(let appliedFrames, _):
            await worldActor.commit(first, appliedFrames: appliedFrames)
            try requireAppliedFramesVisible(appliedFrames, plan: first, context: name)
            return first.desiredLayout.layout.tiled

        case .fail(_, let failureCount, let summary):
            throw RealAppWindowVerifierFailure("\(name) failed applying \(failureCount) real app window(s): \(summary)")

        case .clamp(let appliedFrames, let observedConstraints, let shouldRetry, let summary):
            await worldActor.recordAppliedFrames(appliedFrames)
            await worldActor.recordObservedConstraints(observedConstraints)
            guard shouldRetry else {
                throw RealAppWindowVerifierFailure("\(name) clamped without retry: \(summary)")
            }
            let retry: CommandPlanResult
            switch await worldActor.replanExternalGeometryAfterClamp(first) {
            case .success(let plan):
                retry = plan
            case .failure(let error):
                throw RealAppWindowVerifierFailure("\(name) retry after clamp failed: \(error.message)")
            }
            let retryResult = applier.apply(retry)
            switch plannedLayoutApplyDecision(plan: retry, applyResult: retryResult, retryOnClamp: false) {
            case .commit(let retryAppliedFrames, _):
                await worldActor.commit(retry, appliedFrames: retryAppliedFrames)
                try requireAppliedFramesVisible(
                    retryAppliedFrames,
                    plan: retry,
                    context: "\(name) retry after clamp"
                )
                return retry.desiredLayout.layout.tiled
            case .fail(_, let failureCount, let retrySummary):
                throw RealAppWindowVerifierFailure(
                    "\(name) failed after clamp retry applying \(failureCount) real app window(s): initial=\(summary); retry=\(retrySummary)"
                )
            case .clamp(_, _, _, let retrySummary):
                throw RealAppWindowVerifierFailure("\(name) still clamped after retry: initial=\(summary); retry=\(retrySummary)")
            }
        }
    }

    private static func applyFirstSuccessfulWorkflowCommand(
        _ context: String,
        plans: [(name: String, plan: () async -> Result<CommandPlanResult, CommandError>)],
        worldActor: WorldActor,
        applier: LayoutApplier
    ) async throws {
        var rejected: [String] = []
        for entry in plans {
            switch await entry.plan() {
            case .success:
                try await applyWorkflowCommand(entry.name, plan: entry.plan, worldActor: worldActor, applier: applier)
                return
            case .failure(let error):
                rejected.append("\(entry.name): \(error.message)")
            }
        }
        throw RealAppWindowVerifierFailure("\(context) had no valid real-app command plan: \(rejected.joined(separator: "; "))")
    }

    private static func currentWorkflowMetadata(
        for original: RealAppOriginal,
        using axClient: AXClient
    ) throws -> WindowMetadata {
        let candidates = axClient.windowSnapshot().windows
            .filter {
                $0.bundleID.raw == original.bundleID
                    && $0.isResizable
                    && !$0.isMinimized
                    && $0.frame.width >= original.spec.minimumWindowSize.width
                    && $0.frame.height >= original.spec.minimumWindowSize.height
            }
            .sorted { $0.frame.area > $1.frame.area }
        if let exact = candidates.first(where: { $0.id == original.metadata.id }) {
            return exact
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
        context: String
    ) throws {
        guard !appliedFrames.isEmpty else {
            throw RealAppWindowVerifierFailure("\(context) applied no frames")
        }
        let plannedFrames = plan.desiredLayout.layout.tiled
        let missingWindowIDs = plannedFrames.keys.filter { appliedFrames[$0] == nil }
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
            guard frameSettledOnPlan(frame, plannedFrame) else {
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
        frame.matches(plannedFrame, tolerance: frameWriteSettleTolerance)
            || frameWriteApproximatelySettled(
                target: plannedFrame,
                actual: frame,
                tolerance: Double(frameWriteSettleTolerance),
                maxEdgeDrift: 8,
                minimumOverlapRatio: 0.99
            )
    }

    private static func focusIfPossible(
        _ metadata: WindowMetadata,
        appName: String,
        using axClient: AXClient
    ) async throws {
        switch axClient.focusWindow(metadata) {
        case .success:
            try? await Task.sleep(nanoseconds: 120_000_000)
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

    private static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func preexistingBrowserWindowIDs(
        for spec: RealAppSpec,
        bundleID: String,
        using axClient: AXClient
    ) -> Set<WindowID> {
        guard spec.pattern == .browser else { return [] }
        return Set(axClient.windowSnapshot().windows
            .filter { $0.bundleID.raw == bundleID }
            .map(\.id))
    }

    private static func cleanupApp(_ original: RealAppOriginal, using axClient: AXClient) throws {
        if original.wasRunningBeforeTest {
            try restoreWindow(
                original.metadata,
                bundleID: original.bundleID,
                appName: original.spec.name,
                to: original.frame,
                using: axClient
            )
        } else {
            quitApp(bundleID: original.bundleID, appName: original.spec.name)
        }
    }

    private static func quitApp(bundleID: String, appName: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.forceTerminate()
        }
        print("REAL APP WORKFLOW VERIFY: quit \(appName) after launching it for verification")
    }

    private static func launch(spec: RealAppSpec, bundleID: String) throws {
        if spec.name == "Finder" {
            try FinderWindowOpener.openHomeWindow()
            return
        }
        let process = Process()
        if let launchExecutablePath = spec.launchExecutablePath {
            process.executableURL = URL(fileURLWithPath: launchExecutablePath)
            process.arguments = spec.launchArguments
        } else if spec.name == "Google Chrome" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", spec.launchName, "--args"] + spec.launchArguments
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
    }

    private static func waitForUsableWindow(
        spec: RealAppSpec,
        bundleID: String,
        using axClient: AXClient,
        excluding excludedIDs: Set<WindowID> = []
    ) throws -> WindowMetadata {
        let deadline = Date().addingTimeInterval(14)
        var lastCandidates: [WindowMetadata] = []
        var lastSeen: [WindowMetadata] = []
        while Date() < deadline {
            lastSeen = axClient.windowSnapshot().windows
                .filter {
                    $0.bundleID.raw == bundleID
                }
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
            if let preferred = lastCandidates
                .filter({ candidate in
                    spec.preferredTitleSubstrings.contains { token in
                        candidate.title.localizedCaseInsensitiveContains(token)
                    }
                })
                .first
            {
                return preferred
            }
            if let candidate = lastCandidates.first {
                return candidate
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        let seen = lastCandidates
            .map { "\($0.id.description) \($0.frame.shortDescription) resizable=\($0.isResizable)" }
            .joined(separator: ", ")
        let allSeen = lastSeen
            .map { "\($0.id.description) \($0.frame.shortDescription) resizable=\($0.isResizable) minimized=\($0.isMinimized) title=\"\($0.title)\"" }
            .joined(separator: ", ")
        throw RealAppWindowVerifierFailure(
            "\(spec.name) did not expose a usable resizable AX window for bundle \(bundleID) with minimum size \(spec.minimumWindowSize.shortDescription); candidates=[\(seen)] allVisibleForBundle=[\(allSeen)]"
        )
    }

    private static func threeWindowVerticalStackFrames(in visible: CGRect) throws -> [CGRect] {
        let margin: CGFloat = 40
        let gap: CGFloat = 18
        let width = min(max(visible.width * 0.46, 1_180), visible.width - margin * 2)
        let height = (visible.height - margin * 2 - gap * 2) / 3
        guard width > 0, height >= 320 else {
            throw RealAppWindowVerifierFailure(
                "three Firefox vertical stack requires at least 320pt per window: visible=\(visible.debugDescription)"
            )
        }
        let x = visible.minX + margin
        let y = visible.minY + margin
        return (0..<3).map { index in
            CGRect(
                x: x,
                y: y + CGFloat(index) * (height + gap),
                width: width,
                height: height
            ).standardized
        }
    }

    private static func verifyFrameWrite(
        _ target: CGRect,
        metadata: WindowMetadata,
        appName: String,
        step: Int,
        using axClient: AXClient
    ) throws -> CGRect {
        let actual: CGRect
        switch axClient.setFrame(metadata, to: target) {
        case .converged(let frame):
            actual = frame
        case .clamped(let frame, let observed):
            guard frameWriteApproximatelySettled(
                target: target,
                actual: frame,
                tolerance: Double(frameWriteSettleTolerance)
            ) else {
                throw RealAppWindowVerifierFailure(
                    "\(appName) step \(step) clamped instead of settling: target=\(target.debugDescription) actual=\(frame.debugDescription) observed=\(observed)"
                )
            }
            actual = frame
        case .failed(let error):
            throw RealAppWindowVerifierFailure(
                "\(appName) step \(step) frame write failed: \(error.description)"
            )
        }

        guard frameWriteApproximatelySettled(
            target: target,
            actual: actual,
            tolerance: Double(frameWriteSettleTolerance)
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

    private static func restoreWindow(
        _ original: WindowMetadata,
        bundleID: String,
        appName: String,
        to frame: CGRect,
        using axClient: AXClient
    ) throws {
        var failures: [String] = []
        switch axClient.setFrame(original, to: frame) {
        case .converged, .clamped:
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
            switch axClient.setFrame(candidate, to: frame) {
            case .converged, .clamped:
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

    private static func displayContaining(
        _ frame: CGRect,
        displays: [DisplayID: DisplayInfo]
    ) -> DisplayInfo? {
        if let byIntersection = displays.values.max(by: {
            $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area
        }), byIntersection.visibleFrame.intersection(frame).area > 0 {
            return byIntersection
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.values.min {
            $0.visibleFrame.center.distanceSquared(to: center) < $1.visibleFrame.center.distanceSquared(to: center)
        }
    }
}

private struct RealAppSpec {
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

private struct RealAppOriginal {
    let spec: RealAppSpec
    let bundleID: String
    let metadata: WindowMetadata
    let frame: CGRect
    let wasRunningBeforeTest: Bool
}

private enum RealAppPattern {
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

private func terminalSpec() -> RealAppSpec {
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
        preferredTitleSubstrings: ["Example Domain"]
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
        preferredTitleSubstrings: ["Example Domain"]
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

private struct RealAppWindowVerifierFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = "real app window verification failed: \(message)"
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var shortDescription: String {
        "(\(Int(minX)),\(Int(minY)),\(Int(width)),\(Int(height)))"
    }

    func matches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

private extension CGSize {
    var shortDescription: String {
        "(\(Int(width)),\(Int(height)))"
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
#endif
