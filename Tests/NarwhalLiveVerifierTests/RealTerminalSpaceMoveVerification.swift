#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import CoreGraphics
import Foundation
import NarwhalCore

@MainActor
enum RealTerminalSpaceMoveVerification {
    static func verifyRoundTrip() async -> (passed: Bool, message: String) {
        let axClient = AXClient(processID: -1, settleStrategy: .servicingRunLoop)
        let spaceClient = SpaceClient()
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
            let destinationIndex = activeIndex + 1 < row.spaces.count ? activeIndex + 1 : activeIndex - 1
            let destination = row.spaces[destinationIndex].id
            guard try spaceClient.spaces(forWindow: tracked.metadata.id).get().contains(active) else {
                throw RealAppWindowVerifierFailure("Terminal was not assigned to the active source Space")
            }

            try await dragWindowAcrossSpace(
                windowID: tracked.metadata.id,
                frame: tracked.metadata.frame,
                direction: destinationIndex > activeIndex ? .right : .left,
                destination: destination,
                display: targetDisplay,
                displays: displays,
                using: spaceClient
            )
            try await requireWindow(tracked.metadata.id, on: destination, using: spaceClient)
            guard LiveWindowServerVerification.frame(for: Int(tracked.metadata.id.raw)) != nil else {
                throw RealAppWindowVerifierFailure("Terminal WindowServer surface was absent on destination Space")
            }

            let destinationFrame = LiveWindowServerVerification.frame(for: Int(tracked.metadata.id.raw))
                ?? tracked.metadata.frame
            try await dragWindowAcrossSpace(
                windowID: tracked.metadata.id,
                frame: destinationFrame,
                direction: destinationIndex > activeIndex ? .left : .right,
                destination: active,
                display: targetDisplay,
                displays: displays,
                using: spaceClient
            )
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

    private enum HorizontalDirection {
        case left
        case right

        var symbolicHotKeyID: String {
            switch self {
            case .left:
                return "79"
            case .right:
                return "81"
            }
        }
    }

    private struct SpaceSwitchShortcut {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    private static func dragWindowAcrossSpace(
        windowID: WindowID,
        frame: CGRect,
        direction: HorizontalDirection,
        destination: SpaceID,
        display: DisplayInfo,
        displays: [DisplayID: DisplayInfo],
        using spaceClient: SpaceClient
    ) async throws {
        let originalCursor = CGEvent(source: nil)?.location
        let shortcut = try configuredShortcut(for: direction)
        let titleBarPoint = CGPoint(x: frame.midX, y: frame.minY + 12)
        let dragPoint = CGPoint(x: titleBarPoint.x + 18, y: titleBarPoint.y)
        guard let originalFrame = LiveWindowServerVerification.frame(for: Int(windowID.raw)) else {
            throw RealAppWindowVerifierFailure("Terminal WindowServer surface was unavailable before dragging")
        }
        CGWarpMouseCursorPosition(titleBarPoint)
        await settleLiveVerifier(for: 0.08)

        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: titleBarPoint,
            mouseButton: .left
        ),
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: dragPoint,
            mouseButton: .left
        ),
        let mouseDragged = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: dragPoint,
            mouseButton: .left
        ),
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false)
        else {
            throw RealAppWindowVerifierFailure("Could not create Space-move input events")
        }

        keyDown.flags = shortcut.flags
        keyUp.flags = shortcut.flags
        mouseDown.post(tap: .cghidEventTap)
        await settleLiveVerifier(for: 0.15)
        mouseDragged.post(tap: .cghidEventTap)
        await settleLiveVerifier(for: 0.15)

        do {
            guard let draggedFrame = LiveWindowServerVerification.frame(for: Int(windowID.raw)),
                  abs(draggedFrame.minX - originalFrame.minX) >= 8
            else {
                throw RealAppWindowVerifierFailure("Synthetic title-bar drag did not move the Terminal surface")
            }
            keyDown.post(tap: .cghidEventTap)
            await settleLiveVerifier(for: 0.05)
            keyUp.post(tap: .cghidEventTap)
            try await requireActiveSpace(
                destination,
                display: display,
                displays: displays,
                using: spaceClient
            )
            mouseUp.post(tap: .cghidEventTap)
        } catch {
            mouseUp.post(tap: .cghidEventTap)
            if let originalCursor { CGWarpMouseCursorPosition(originalCursor) }
            throw error
        }
        await settleLiveVerifier(for: 0.25)
        if let originalCursor { CGWarpMouseCursorPosition(originalCursor) }
    }

    private static func configuredShortcut(for direction: HorizontalDirection) throws -> SpaceSwitchShortcut {
        guard let hotKeys = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ) as? NSDictionary,
        let entry = hotKeys[direction.symbolicHotKeyID] as? NSDictionary,
        (entry["enabled"] as? NSNumber)?.boolValue == true,
        let value = entry["value"] as? NSDictionary,
        let parameters = value["parameters"] as? NSArray,
        parameters.count >= 3,
        let keyCode = parameters[1] as? NSNumber,
        let modifierFlags = parameters[2] as? NSNumber
        else {
            throw RealAppWindowVerifierFailure(
                "Mission Control shortcut \(direction.symbolicHotKeyID) is unavailable or disabled"
            )
        }

        let keyboardModifierMask = CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskSecondaryFn.rawValue
        return SpaceSwitchShortcut(
            keyCode: CGKeyCode(keyCode.uint16Value),
            flags: CGEventFlags(rawValue: modifierFlags.uint64Value & keyboardModifierMask)
        )
    }

    private static func requireWindow(
        _ windowID: WindowID,
        on spaceID: SpaceID,
        using spaceClient: SpaceClient
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try spaceClient.spaces(forWindow: windowID).get().contains(spaceID) { return }
            await settleLiveVerifier(for: 0.05)
        }
        throw RealAppWindowVerifierFailure("Window \(windowID.description) never joined Space \(spaceID.raw)")
    }

    private static func requireActiveSpace(
        _ spaceID: SpaceID,
        display: DisplayInfo,
        displays: [DisplayID: DisplayInfo],
        using spaceClient: SpaceClient
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if spaceClient.managedDisplaySpaceRows(displays: displays)[display.id]?.activeSpace == spaceID { return }
            await settleLiveVerifier(for: 0.05)
        }
        throw RealAppWindowVerifierFailure("Display never activated Space \(spaceID.raw)")
    }
}
#endif
