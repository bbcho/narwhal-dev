#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import CoreGraphics
import Foundation
import NarwhalCore

@MainActor
enum RealTerminalSpaceMoveVerification {
    static func verifyProductionHotkey() async -> (passed: Bool, message: String) {
        let axClient = AXClient(processID: -1, settleStrategy: .servicingRunLoop)
        let spaceClient = SpaceClient()
        var runtime: ProductionRuntimeHarness?
        var terminal: RealAppOriginal?
        var sourceSpace: SpaceID?
        var display: DisplayInfo?
        do {
            let activeRuntime = try ProductionRuntimeHarness.start()
            runtime = activeRuntime
            let ready = try await activeRuntime.waitUntilReady()

            let tracked = try await RealAppLaunchSupport.launchTerminal(
                token: "production-space-hotkey",
                excluding: [],
                using: axClient
            )
            terminal = tracked
            try await requireTrackedFocusedWindow(
                tracked.metadata.id,
                baselineWindowCount: ready.windowCount,
                runtime: activeRuntime
            )
            let displays = DisplayClient().currentDisplays()
            guard let targetDisplay = displays.values.first(where: {
                $0.frame.contains(CGPoint(x: tracked.metadata.frame.midX, y: tracked.metadata.frame.midY))
            }),
            let row = spaceClient.managedDisplaySpaceRows(displays: displays)[targetDisplay.id],
            let active = row.activeSpace
            else {
                throw RealAppWindowVerifierFailure("Production desktop hotkey could not resolve the source display and desktop")
            }
            display = targetDisplay
            sourceSpace = active
            let userSpaces = try spaceClient.userSpaceIDs(in: row.spaces.map(\.id)).get()
            let direction: DesktopMoveDirection = userSpaces.last == active ? .left : .right
            let destination = try adjacentDesktopSpace(in: userSpaces, active: active, direction: direction).get()

            try activeRuntime.send(.center(windowID: tracked.metadata.id))
            try focusTerminal(tracked.metadata.id)
            try postNarwhalDesktopHotkey(direction)
            try await requireWindow(
                tracked.metadata.id,
                on: destination,
                using: spaceClient,
                timeout: 8
            )

            let floatingTiledCount = try activeRuntime.diagnostics().tiledWindowCount
            try activeRuntime.send(.toggleFloat(windowID: tracked.metadata.id))
            try await requireTiledCount(floatingTiledCount + 1, runtime: activeRuntime)
            try activeRuntime.send(.toggleFloat(windowID: tracked.metadata.id))
            try await requireTiledCount(floatingTiledCount, runtime: activeRuntime)

            try focusTerminal(tracked.metadata.id)
            try postNarwhalDesktopHotkey(direction == .right ? .left : .right)
            try await requireWindow(tracked.metadata.id, on: active, using: spaceClient, timeout: 8)

            try activeRuntime.stop()
            runtime = nil
            try await RealAppLaunchSupport.cleanup([tracked], using: axClient)
            terminal = nil
            return (true, "production hotkey moved real Terminal to desktop \(destination.raw) as floating and returned it")
        } catch {
            let runtimeLog = runtime?.logText ?? ""
            runtime?.stopBestEffort()
            if let sourceSpace, let display {
                _ = spaceClient.switchActiveSpace(display: display, to: sourceSpace)
            }
            if let terminal {
                await RealAppLaunchSupport.cleanupBestEffort(
                    [terminal],
                    using: axClient,
                    context: "PRODUCTION TERMINAL DESKTOP HOTKEY"
                )
            }
            return (false, "\(String(describing: error)); runtime log:\n\(runtimeLog.suffix(6_000))")
        }
    }

    static func verifyRoundTrip() async -> (passed: Bool, message: String) {
        let axClient = AXClient(processID: -1, settleStrategy: .servicingRunLoop)
        let spaceClient = SpaceClient()
        let mover = DesktopWindowMover(axClient: axClient, spaceClient: spaceClient)
        var terminal: RealAppOriginal?
        var originalSpace: SpaceID?
        var display: DisplayInfo?
        do {
            let tracked = try await RealAppLaunchSupport.launchTerminal(
                token: "space-round-trip",
                excluding: [],
                using: axClient
            )
            terminal = tracked
            let displays = DisplayClient().currentDisplays()
            guard let targetDisplay = displays.values.first(where: {
                $0.frame.contains(CGPoint(x: tracked.metadata.frame.midX, y: tracked.metadata.frame.midY))
            }) else {
                throw RealAppWindowVerifierFailure("Space move could not identify the Terminal display")
            }
            display = targetDisplay
            guard let row = spaceClient.managedDisplaySpaceRows(displays: displays)[targetDisplay.id],
                  let active = row.activeSpace,
                  let activeIndex = row.spaces.firstIndex(where: { $0.id == active }),
                  row.spaces.count >= 2
            else {
                throw RealAppWindowVerifierFailure("Space move requires two ordinary Spaces on the Terminal display")
            }
            originalSpace = active
            let direction: DesktopMoveDirection = activeIndex + 1 < row.spaces.count ? .right : .left
            let plan = try mover.plan(
                window: tracked.metadata,
                direction: direction,
                display: targetDisplay,
                displays: displays
            ).get()
            let destination = plan.destinationSpace
            guard try spaceClient.spaces(forWindow: tracked.metadata.id).get().contains(active) else {
                throw RealAppWindowVerifierFailure("Terminal was not assigned to the active source Space")
            }

            try await mover.execute(plan).get()
            try await requireWindow(tracked.metadata.id, on: destination, using: spaceClient)
            guard LiveWindowServerVerification.frame(for: Int(tracked.metadata.id.raw)) != nil else {
                throw RealAppWindowVerifierFailure("Terminal WindowServer surface was absent on destination Space")
            }

            let returnPlan = try mover.plan(
                window: tracked.metadata,
                direction: direction == .right ? .left : .right,
                display: targetDisplay,
                displays: displays
            ).get()
            try await mover.execute(returnPlan).get()
            try await requireWindow(tracked.metadata.id, on: active, using: spaceClient)
            guard LiveWindowServerVerification.frame(for: Int(tracked.metadata.id.raw)) != nil else {
                throw RealAppWindowVerifierFailure("Terminal WindowServer surface was absent after returning")
            }

            try await RealAppLaunchSupport.cleanup([tracked], using: axClient)
            terminal = nil
            return (true, "real Terminal moved \(active.raw) -> \(destination.raw) -> \(active.raw)")
        } catch {
            if let originalSpace, let display {
                _ = spaceClient.switchActiveSpace(display: display, to: originalSpace)
            }
            if let terminal {
                await RealAppLaunchSupport.cleanupBestEffort(
                    [terminal],
                    using: axClient,
                    context: "REAL TERMINAL SPACE MOVE"
                )
            }
            return (false, String(describing: error))
        }
    }

    private static func requireWindow(
        _ windowID: WindowID,
        on spaceID: SpaceID,
        using spaceClient: SpaceClient,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try spaceClient.spaces(forWindow: windowID).get().contains(spaceID) { return }
            await settleLiveVerifier(for: 0.05)
        }
        throw RealAppWindowVerifierFailure("Window \(windowID.description) never joined Space \(spaceID.raw)")
    }

    private static func requireTiledCount(
        _ expected: Int,
        runtime: ProductionRuntimeHarness
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try runtime.diagnostics().tiledWindowCount == expected { return }
            await settleLiveVerifier(for: 0.05)
        }
        throw RealAppWindowVerifierFailure("Production runtime did not reach tiled-window count \(expected)")
    }

    private static func requireTrackedFocusedWindow(
        _ windowID: WindowID,
        baselineWindowCount: Int,
        runtime: ProductionRuntimeHarness
    ) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let diagnostics = try runtime.diagnostics()
            if diagnostics.windowCount > baselineWindowCount,
               diagnostics.focusedWindowID == windowID.raw {
                return
            }
            await settleLiveVerifier(for: 0.1)
        }
        throw RealAppWindowVerifierFailure("Production runtime did not track focused \(windowID.description)")
    }

    private static func postNarwhalDesktopHotkey(_ direction: DesktopMoveDirection) throws {
        let keyCode: CGKeyCode
        switch direction {
        case .left:
            keyCode = 123
        case .right:
            keyCode = 124
        }
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            throw RealAppWindowVerifierFailure("Could not create Narwhal desktop hotkey events")
        }
        keyDown.flags = [.maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        keyUp.flags = keyDown.flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func focusTerminal(_ windowID: WindowID) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "tell application \"Terminal\" to set index of window id \(windowID.raw) to 1",
            "-e", "tell application \"Terminal\" to activate"
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RealAppWindowVerifierFailure("Could not focus Terminal \(windowID.description)")
        }
    }

}
#endif
