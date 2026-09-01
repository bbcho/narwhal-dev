import CoreGraphics
import Foundation
import NarwhalCore

struct DesktopSwitchShortcut: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

struct DesktopWindowMovePlan {
    let window: WindowMetadata
    let sourceSpace: SpaceID
    let destinationSpace: SpaceID
    let display: DisplayInfo
    let displays: [DisplayID: DisplayInfo]
    let shortcut: DesktopSwitchShortcut
}

enum DesktopWindowMoveError: Error, Equatable, CustomStringConvertible {
    case shortcutUnavailable(DesktopMoveDirection)
    case desktopTopologyUnavailable(DisplayID)
    case noAdjacentDesktop(DesktopMoveDirection)
    case windowNotOnActiveDesktop(WindowID, SpaceID)
    case spaceClient(SpaceClientError)
    case windowServerFrameUnavailable(WindowID)
    case inputEventCreationFailed
    case dragDidNotEngage(WindowID)
    case desktopTransitionTimedOut(SpaceID)
    case windowMoveTimedOut(WindowID, SpaceID)
    case movedWindowNotVisible(WindowID)
    case cancelled

    var description: String {
        switch self {
        case .shortcutUnavailable(let direction):
            return "Mission Control shortcut for desktop \(direction.rawValue) is unavailable or disabled"
        case .desktopTopologyUnavailable(let displayID):
            return "desktop topology unavailable for display \(displayID.raw)"
        case .noAdjacentDesktop(let direction):
            return "no desktop exists to the \(direction.rawValue)"
        case .windowNotOnActiveDesktop(let windowID, let spaceID):
            return "window \(windowID.description) is not on active desktop \(spaceID.raw)"
        case .spaceClient(let error):
            return error.description
        case .windowServerFrameUnavailable(let windowID):
            return "WindowServer frame unavailable for \(windowID.description)"
        case .inputEventCreationFailed:
            return "could not create desktop-move input events"
        case .dragDidNotEngage(let windowID):
            return "title-bar drag did not engage \(windowID.description)"
        case .desktopTransitionTimedOut(let spaceID):
            return "desktop transition to \(spaceID.raw) timed out"
        case .windowMoveTimedOut(let windowID, let spaceID):
            return "window \(windowID.description) did not join desktop \(spaceID.raw)"
        case .movedWindowNotVisible(let windowID):
            return "moved window \(windowID.description) is not visible on the destination desktop"
        case .cancelled:
            return "desktop move cancelled"
        }
    }

}

@MainActor
struct DesktopWindowMover {
    private let axClient: AXClient
    private let spaceClient: SpaceClient
    private let shortcutPreferences: () -> NSDictionary?

    init(
        axClient: AXClient,
        spaceClient: SpaceClient,
        shortcutPreferences: @escaping () -> NSDictionary? = {
            CFPreferencesCopyAppValue(
                "AppleSymbolicHotKeys" as CFString,
                "com.apple.symbolichotkeys" as CFString
            ) as? NSDictionary
        }
    ) {
        self.axClient = axClient
        self.spaceClient = spaceClient
        self.shortcutPreferences = shortcutPreferences
    }

    func plan(
        window: WindowMetadata,
        direction: DesktopMoveDirection,
        display: DisplayInfo,
        displays: [DisplayID: DisplayInfo]
    ) -> Result<DesktopWindowMovePlan, DesktopWindowMoveError> {
        guard let row = spaceClient.managedDisplaySpaceRows(displays: displays)[display.id],
              let activeSpace = row.activeSpace
        else {
            return .failure(.desktopTopologyUnavailable(display.id))
        }

        let userSpaces: [SpaceID]
        switch spaceClient.userSpaceIDs(in: row.spaces.map(\.id)) {
        case .success(let value):
            userSpaces = value
        case .failure(let error):
            return .failure(.spaceClient(error))
        }

        let destinationSpace: SpaceID
        switch adjacentDesktopSpace(in: userSpaces, active: activeSpace, direction: direction) {
        case .success(let value):
            destinationSpace = value
        case .failure(.activeDesktopMissing):
            return .failure(.desktopTopologyUnavailable(display.id))
        case .failure(.noAdjacentDesktop):
            return .failure(.noAdjacentDesktop(direction))
        }

        switch spaceClient.spaces(forWindow: window.id) {
        case .success(let spaces) where spaces.contains(activeSpace):
            break
        case .success:
            return .failure(.windowNotOnActiveDesktop(window.id, activeSpace))
        case .failure(let error):
            return .failure(.spaceClient(error))
        }

        guard let preferences = shortcutPreferences() else {
            return .failure(.shortcutUnavailable(direction))
        }
        return desktopSwitchShortcut(for: direction, in: preferences).map { shortcut in
            DesktopWindowMovePlan(
                window: window,
                sourceSpace: activeSpace,
                destinationSpace: destinationSpace,
                display: display,
                displays: displays,
                shortcut: shortcut
            )
        }
    }

    func execute(_ plan: DesktopWindowMovePlan) async -> Result<Void, DesktopWindowMoveError> {
        let originalFrame: CGRect
        switch axClient.windowServerFrame(of: plan.window) {
        case .success(let frame):
            originalFrame = frame
        case .failure:
            return .failure(.windowServerFrameUnavailable(plan.window.id))
        }

        let originalCursor = CGEvent(source: nil)?.location
        defer {
            if let originalCursor { _ = CGWarpMouseCursorPosition(originalCursor) }
        }
        let titleBarPoint = CGPoint(x: originalFrame.midX, y: originalFrame.minY + 12)
        let dragPoint = CGPoint(x: titleBarPoint.x + 18, y: titleBarPoint.y)
        _ = CGWarpMouseCursorPosition(titleBarPoint)
        guard await pause(for: 0.08) else { return .failure(.cancelled) }

        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: titleBarPoint,
            mouseButton: .left
        ),
        let mouseDragged = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: dragPoint,
            mouseButton: .left
        ),
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: dragPoint,
            mouseButton: .left
        ),
        let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: plan.shortcut.keyCode,
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: plan.shortcut.keyCode,
            keyDown: false
        ) else {
            return .failure(.inputEventCreationFailed)
        }

        keyDown.flags = plan.shortcut.flags
        keyUp.flags = plan.shortcut.flags
        var mouseIsDown = false
        var keyIsDown = false
        defer {
            if keyIsDown { keyUp.post(tap: .cghidEventTap) }
            if mouseIsDown { mouseUp.post(tap: .cghidEventTap) }
        }

        mouseDown.post(tap: .cghidEventTap)
        mouseIsDown = true
        guard await pause(for: 0.15) else { return .failure(.cancelled) }
        mouseDragged.post(tap: .cghidEventTap)
        guard await pause(for: 0.15) else { return .failure(.cancelled) }

        guard case .success(let draggedFrame) = axClient.windowServerFrame(of: plan.window),
              abs(draggedFrame.minX - originalFrame.minX) >= 8
        else {
            return .failure(.dragDidNotEngage(plan.window.id))
        }

        keyDown.post(tap: .cghidEventTap)
        keyIsDown = true
        guard await pause(for: 0.05) else { return .failure(.cancelled) }
        keyUp.post(tap: .cghidEventTap)
        keyIsDown = false
        guard await waitForActiveDesktop(plan.destinationSpace, plan: plan) else {
            return .failure(.desktopTransitionTimedOut(plan.destinationSpace))
        }

        mouseUp.post(tap: .cghidEventTap)
        mouseIsDown = false
        guard await pause(for: 0.25) else { return .failure(.cancelled) }
        guard await waitForWindow(plan.window.id, on: plan.destinationSpace) else {
            return .failure(.windowMoveTimedOut(plan.window.id, plan.destinationSpace))
        }
        guard case .success = axClient.windowServerFrame(of: plan.window) else {
            return .failure(.movedWindowNotVisible(plan.window.id))
        }
        return .success(())
    }

    private func waitForActiveDesktop(_ spaceID: SpaceID, plan: DesktopWindowMovePlan) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if spaceClient.managedDisplaySpaceRows(displays: plan.displays)[plan.display.id]?.activeSpace == spaceID {
                return true
            }
            guard await pause(for: 0.05) else { return false }
        }
        return false
    }

    private func waitForWindow(_ windowID: WindowID, on spaceID: SpaceID) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if case .success(let spaces) = spaceClient.spaces(forWindow: windowID), spaces.contains(spaceID) {
                return true
            }
            guard await pause(for: 0.05) else { return false }
        }
        return false
    }

    private func pause(for seconds: Double) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return true
        } catch {
            return false
        }
    }
}

func desktopSwitchShortcut(
    for direction: DesktopMoveDirection,
    in hotKeys: NSDictionary
) -> Result<DesktopSwitchShortcut, DesktopWindowMoveError> {
    let symbolicHotKeyID: String
    switch direction {
    case .left:
        symbolicHotKeyID = "79"
    case .right:
        symbolicHotKeyID = "81"
    }

    guard let entry = hotKeys[symbolicHotKeyID] as? NSDictionary,
          (entry["enabled"] as? NSNumber)?.boolValue == true,
          let value = entry["value"] as? NSDictionary,
          let parameters = value["parameters"] as? NSArray,
          parameters.count >= 3,
          let keyCode = parameters[1] as? NSNumber,
          let modifierFlags = parameters[2] as? NSNumber
    else {
        return .failure(.shortcutUnavailable(direction))
    }

    let keyboardModifierMask = CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue
    return .success(DesktopSwitchShortcut(
        keyCode: CGKeyCode(keyCode.uint16Value),
        flags: CGEventFlags(rawValue: modifierFlags.uint64Value & keyboardModifierMask)
    ))
}
