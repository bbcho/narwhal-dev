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

    private func expectPassed(_ result: (passed: Bool, message: String)) throws {
        guard result.passed else {
            throw RealAppWindowVerifierFailure(result.message)
        }
    }
}

@MainActor
enum RealAppWindowVerification {
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
        try launch(spec: spec, bundleID: bundleID)

        let axClient = AXClient(processID: -1)
        let original = try waitForUsableWindow(spec: spec, bundleID: bundleID, using: axClient)
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

        guard actuals.contains(where: { !$0.matches(restoreFrame, tolerance: 8) }) else {
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
            try launch(spec: spec, bundleID: bundleID)
            let metadata: WindowMetadata
            do {
                metadata = try waitForUsableWindow(spec: spec, bundleID: bundleID, using: axClient)
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
            try await focusIfPossible(entry.metadata, appName: entry.spec.name, using: axClient)
            let direction = directions[min(index, directions.count - 1)]
            try await applyWorkflowCommand(
                "mixed \(entry.spec.name) push \(direction.rawValue)",
                plan: { await worldActor.planPush(entry.metadata.id, direction: direction) },
                worldActor: worldActor,
                applier: applier
            )
        }

        let resizeTarget = browser ?? sequence.last!
        try await applyFirstSuccessfulWorkflowCommand(
            "mixed \(resizeTarget.spec.name) resize split",
            plans: Direction.allCases.map { direction in
                (
                    name: "mixed \(resizeTarget.spec.name) resize \(direction.rawValue)",
                    plan: { await worldActor.planResize(resizeTarget.metadata.id, direction: direction, delta: 0.10) }
                )
            },
            worldActor: worldActor,
            applier: applier
        )

        try await applyWorkflowCommand(
            "mixed balance real-app workspace",
            plan: { await worldActor.planBalanceWorkspace(containing: resizeTarget.metadata.id) },
            worldActor: worldActor,
            applier: applier,
            allowNoMove: true
        )

        return "mixed-app workflow apps=\(sequence.map { $0.spec.name }.joined(separator: ","))"
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

    private static func applyWorkflowCommand(
        _ name: String,
        plan: () async -> Result<CommandPlanResult, CommandError>,
        worldActor: WorldActor,
        applier: LayoutApplier,
        allowNoMove: Bool = false
    ) async throws {
        let first = try await requireWorkflowPlan(name, plan(), allowNoMove: allowNoMove)
        if first.desiredLayout.delta.moves.isEmpty {
            await worldActor.commit(first, appliedFrames: [:])
            return
        }
        let firstResult = applier.apply(first)
        switch plannedLayoutApplyDecision(plan: first, applyResult: firstResult, retryOnClamp: true) {
        case .commit(let appliedFrames, _):
            await worldActor.commit(first, appliedFrames: appliedFrames)
            try requireAppliedFramesVisible(appliedFrames, context: name)

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
                try requireAppliedFramesVisible(retryAppliedFrames, context: "\(name) retry after clamp")
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

    private static func requireAppliedFramesVisible(_ appliedFrames: [WindowID: CGRect], context: String) throws {
        guard !appliedFrames.isEmpty else {
            throw RealAppWindowVerifierFailure("\(context) applied no frames")
        }
        for (windowID, frame) in appliedFrames {
            let serverFrame = LiveWindowServerVerification.waitForFrame(
                windowNumber: Int(windowID.raw),
                matching: frame,
                tolerance: 4
            )
            guard serverFrame?.matches(frame, tolerance: 4) == true else {
                throw RealAppWindowVerifierFailure(
                    "\(context) WindowServer frame mismatch for \(windowID.description): expected=\(frame.debugDescription) actual=\(serverFrame?.debugDescription ?? "nil")"
                )
            }
        }
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
    }

    private static func waitForUsableWindow(
        spec: RealAppSpec,
        bundleID: String,
        using axClient: AXClient
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
                        && $0.frame.width >= spec.minimumWindowSize.width
                        && $0.frame.height >= spec.minimumWindowSize.height
                }
                .sorted { $0.frame.area > $1.frame.area }
            if let preferred = lastCandidates.first(where: { candidate in
                spec.preferredTitleSubstrings.contains { token in
                    candidate.title.localizedCaseInsensitiveContains(token)
                }
            }) {
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
            throw RealAppWindowVerifierFailure(
                "\(appName) step \(step) clamped instead of settling: target=\(target.debugDescription) actual=\(frame.debugDescription) observed=\(observed)"
            )
        case .failed(let error):
            throw RealAppWindowVerifierFailure(
                "\(appName) step \(step) frame write failed: \(error.description)"
            )
        }

        guard frameWriteApproximatelySettled(target: target, actual: actual, tolerance: 2) else {
            throw RealAppWindowVerifierFailure(
                "\(appName) step \(step) did not settle near target: target=\(target.debugDescription) actual=\(actual.debugDescription)"
            )
        }

        let serverFrame = LiveWindowServerVerification.waitForFrame(
            windowNumber: Int(metadata.id.raw),
            matching: actual,
            tolerance: 3
        )
        guard serverFrame?.matches(actual, tolerance: 3) == true else {
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
        let maxFirstWidth = visibleFrame.width - 96
        let maxSecondWidth = visibleFrame.width - 120
        let maxFirstHeight = visibleFrame.height - 96
        let maxSecondHeight = visibleFrame.height - 120
        let firstWidth: CGFloat
        let firstHeight: CGFloat
        let secondWidth: CGFloat
        let secondHeight: CGFloat
        switch spec.name {
        case "Firefox":
            firstWidth = min(originalFrame.width + 40, maxFirstWidth)
            firstHeight = min(originalFrame.height + 40, maxFirstHeight)
            secondWidth = min(originalFrame.width + 24, maxSecondWidth)
            secondHeight = min(originalFrame.height + 28, maxSecondHeight)
        case "System Settings":
            firstWidth = min(originalFrame.width + 32, maxFirstWidth)
            firstHeight = min(max(max(visibleFrame.height * 0.68, 560), originalFrame.height), maxFirstHeight)
            secondWidth = min(originalFrame.width + 16, maxSecondWidth)
            secondHeight = min(max(max(visibleFrame.height * 0.60, 520), originalFrame.height), maxSecondHeight)
        default:
            firstWidth = min(max(max(visibleFrame.width * 0.62, 760), originalFrame.width + 40), maxFirstWidth)
            firstHeight = min(max(max(visibleFrame.height * 0.68, 560), originalFrame.height + 240), maxFirstHeight)
            secondWidth = min(max(max(visibleFrame.width * 0.54, 760), originalFrame.width), maxSecondWidth)
            secondHeight = min(max(max(visibleFrame.height * 0.60, 520), originalFrame.height + 160), maxSecondHeight)
        }
        guard firstWidth > 0,
              firstHeight > 0,
              secondWidth > 0,
              secondHeight > 0,
              firstWidth >= originalFrame.width,
              secondWidth >= originalFrame.width
        else {
            throw RealAppWindowVerifierFailure(
                "\(spec.name) original window is too large for non-clamping real-app frame targets: original=\(originalFrame.debugDescription) visible=\(visibleFrame.debugDescription)"
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
        launchArguments: ["https://example.com/?narwhal-real-app=chrome"],
        minimumWindowSize: CGSize(width: 420, height: 320),
        required: false,
        pattern: .browser,
        workflowDirections: Direction.allCases,
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
        finderSpec(),
        safariSpec(),
        terminalSpec(),
        systemSettingsSpec(),
        chromeSpec(),
        firefoxSpec(),
        kittySpec(),
        dockerSpec(),
        teamsSpec(),
        outlookSpec(),
        notionSpec(),
        whatsAppSpec()
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
