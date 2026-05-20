import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import NarwhalAppSupport
import NarwhalCore

struct FocusedWindowSnapshot: Equatable, Sendable {
    let id: WindowID
    let bundleID: BundleID
    let processID: pid_t
    let title: String
    let role: String
    let subrole: String
    let frame: CGRect
    let isResizable: Bool
    let isMinimized: Bool
    let isFullscreen: Bool

    var metadata: WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: bundleID,
            title: title,
            role: role,
            pid: processID,
            frame: frame,
            isResizable: isResizable,
            isMinimized: isMinimized
        )
    }

    var focusBorderTarget: FocusBorderTarget {
        FocusBorderTarget(
            windowID: id,
            frame: frame,
            traits: FocusBorderWindowTraits(
                role: role,
                subrole: subrole,
                isResizable: isResizable,
                isFullscreen: isFullscreen
            )
        )
    }

    var logDescription: String {
        "id=\(id.description) pid=\(processID) bundle=\(bundleID.raw) title=\"\(title)\" role=\(role) subrole=\(subrole) frame=\(frame.debugDescription) fullscreen=\(isFullscreen)"
    }
}

enum AXClientError: Error, CustomStringConvertible, Sendable {
    case copyAttributeFailed(String, AXError)
    case missingFocusedWindow
    case focusedWindowWrongType
    case pidUnavailable(AXError)
    case pointAttributeInvalid(String, AXError)
    case sizeAttributeInvalid(String, AXError)
    case boolAttributeInvalid(String, AXError)
    case focusedWindowUnmatchedToCGWindow
    case windowElementNotFound(WindowID)
    case windowsAttributeInvalid(pid_t, AXError)
    case setAttributeFailed(String, AXError)
    case performActionFailed(String, AXError)
    case applicationActivateFailed(pid_t)
    case frameDidNotConverge(target: CGRect, actual: CGRect, attempts: Int)
    case visibleWindowListUnavailable

    var description: String {
        switch self {
        case .copyAttributeFailed(let attribute, let error):
            return "\(attribute) failed with \(error)"
        case .missingFocusedWindow:
            return "no focused window"
        case .focusedWindowWrongType:
            return "focused AX value was not a window element"
        case .pidUnavailable(let error):
            return "pid unavailable with \(error)"
        case .pointAttributeInvalid(let attribute, let error):
            return "\(attribute) point unavailable with \(error)"
        case .sizeAttributeInvalid(let attribute, let error):
            return "\(attribute) size unavailable with \(error)"
        case .boolAttributeInvalid(let attribute, let error):
            return "\(attribute) bool unavailable with \(error)"
        case .focusedWindowUnmatchedToCGWindow:
            return "focused AX window could not be matched to a CGWindowID"
        case .windowElementNotFound(let id):
            return "AX window element not found for \(id.description)"
        case .windowsAttributeInvalid(let pid, let error):
            return "AXWindows unavailable for pid \(pid) with \(error)"
        case .setAttributeFailed(let attribute, let error):
            return "setting \(attribute) failed with \(error)"
        case .performActionFailed(let action, let error):
            return "\(action) failed with \(error)"
        case .applicationActivateFailed(let pid):
            return "activating application pid=\(pid) failed"
        case .frameDidNotConverge(let target, let actual, let attempts):
            return "frame write did not converge after \(attempts) attempts target=\(target.debugDescription) actual=\(actual.debugDescription)"
        case .visibleWindowListUnavailable:
            return "visible CG window list unavailable"
        }
    }
}

enum AXFrameWriteOutcome: Sendable {
    case converged(actual: CGRect)
    case clamped(actual: CGRect, observed: WindowConstraints)
    case failed(AXClientError)
}

struct AXClient {
    private let inventoryFilter: WindowInventoryFilter

    init(processID: pid_t = getpid()) {
        inventoryFilter = WindowInventoryFilter(currentProcessID: processID)
    }

    func windowSnapshot() -> AXWindowSnapshot {
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return AXWindowSnapshot(
                windows: [],
                quality: .permissionDenied(AXClientError.visibleWindowListUnavailable.description)
            )
        }

        let metadata = windows.compactMap(windowMetadata(from:))
            .sorted { $0.id.raw < $1.id.raw }
        return AXWindowSnapshot(windows: metadata, quality: .complete)
    }

    func visibleWindowIDs() -> Result<Set<WindowID>, AXClientError> {
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return .failure(.visibleWindowListUnavailable)
        }

        let ids: Set<WindowID> = Set(windows.compactMap { window in
            guard
                let layer = window[kCGWindowLayer as String] as? Int,
                let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                let number = window[kCGWindowNumber as String] as? CGWindowID,
                let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDictionary),
                inventoryFilter.accepts(layer: layer, ownerPID: ownerPID, frame: frame)
            else {
                return nil
            }
            return WindowID(raw: number)
        })

        return .success(ids)
    }

    private func windowMetadata(from window: [String: Any]) -> WindowMetadata? {
        guard
            let layer = window[kCGWindowLayer as String] as? Int,
            let number = window[kCGWindowNumber as String] as? CGWindowID,
            let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
            let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: boundsDictionary),
            inventoryFilter.accepts(layer: layer, ownerPID: ownerPID, frame: frame)
        else {
            return nil
        }

        return WindowMetadata(
            id: WindowID(raw: number),
            bundleID: BundleID(raw: NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier ?? ""),
            title: window[kCGWindowName as String] as? String ?? "",
            role: kAXWindowRole,
            pid: ownerPID,
            frame: frame,
            isResizable: isResizable(
                processID: ownerPID,
                title: window[kCGWindowName as String] as? String ?? "",
                role: kAXWindowRole,
                frame: frame,
                windowID: WindowID(raw: number)
            ),
            isMinimized: false
        )
    }

    func focusedWindowSnapshot() -> Result<FocusedWindowSnapshot, AXClientError> {
        let focusedWindow: AXUIElement
        switch focusedWindowElement() {
        case .success(let window):
            focusedWindow = window
        case .failure(let error):
            return .failure(error)
        }

        var pid = pid_t(0)
        let pidError = AXUIElementGetPid(focusedWindow, &pid)
        guard pidError == .success else {
            return .failure(.pidUnavailable(pidError))
        }

        switch focusedWindowFrame(focusedWindow) {
        case .success(let frame):
            let title = stringAttribute(focusedWindow, kAXTitleAttribute)
            let role = stringAttribute(focusedWindow, kAXRoleAttribute)
            let subrole = stringAttribute(focusedWindow, kAXSubroleAttribute)
            guard let id = matchedWindowID(processID: pid, title: title, frame: frame) else {
                return .failure(.focusedWindowUnmatchedToCGWindow)
            }

            let bundleID = BundleID(raw: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")
            let isMinimized = boolAttribute(focusedWindow, kAXMinimizedAttribute, defaultValue: false)
            let isFullscreen = boolAttribute(focusedWindow, "AXFullScreen", defaultValue: false)
            return .success(FocusedWindowSnapshot(
                id: id,
                bundleID: bundleID,
                processID: pid,
                title: title,
                role: role,
                subrole: subrole,
                frame: frame,
                isResizable: isResizable(focusedWindow),
                isMinimized: isMinimized,
                isFullscreen: isFullscreen
            ))
        case .failure(let error):
            return .failure(error)
        }
    }

    func setFocusedWindowFrame(_ frame: CGRect) -> AXFrameWriteOutcome {
        switch focusedWindowElement() {
        case .success(let window):
            return setFrame(window, to: frame)
        case .failure(let error):
            return .failed(error)
        }
    }

    func setFrame(_ window: WindowMetadata, to frame: CGRect) -> AXFrameWriteOutcome {
        switch windowElement(matching: window) {
        case .success(let element):
            return setFrame(element, to: frame)
        case .failure(let error):
            return .failed(error)
        }
    }

    func frame(of window: WindowMetadata) -> Result<CGRect, AXClientError> {
        switch windowElement(matching: window) {
        case .success(let element):
            return focusedWindowFrame(element)
        case .failure(let error):
            return .failure(error)
        }
    }

    func focusWindow(_ window: WindowMetadata) -> Result<Void, AXClientError> {
        guard NSRunningApplication(processIdentifier: window.pid)?.activate(options: []) == true else {
            return .failure(.applicationActivateFailed(window.pid))
        }

        let element: AXUIElement
        switch windowElement(matching: window) {
        case .success(let value):
            element = value
        case .failure(let error):
            return .failure(error)
        }

        let raiseError = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard raiseError == .success else {
            return .failure(.performActionFailed(kAXRaiseAction, raiseError))
        }

        switch setBool(true, attribute: kAXMainAttribute, on: element) {
        case .success:
            return .success(())
        case .failure:
            return setBool(true, attribute: kAXFocusedAttribute, on: element)
        }
    }

    private func focusedWindowElement() -> Result<AXUIElement, AXClientError> {
        let systemElement = AXUIElementCreateSystemWide()
        var focusedAppValue: CFTypeRef?
        let appError = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppValue
        )
        guard appError == .success else {
            return .failure(.copyAttributeFailed(kAXFocusedApplicationAttribute, appError))
        }
        guard let focusedAppValue, CFGetTypeID(focusedAppValue) == AXUIElementGetTypeID() else {
            return .failure(.missingFocusedWindow)
        }

        let focusedApp = focusedAppValue as! AXUIElement

        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            focusedApp,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        )
        if focusedError == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            return .success(focusedValue as! AXUIElement)
        }

        var focusedElementValue: CFTypeRef?
        let elementError = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        if elementError == .success,
           let focusedElementValue,
           CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() {
            let focusedElement = focusedElementValue as! AXUIElement
            if let window = ancestorWindow(from: focusedElement) {
                return .success(window)
            }
        }

        if focusedError != .success {
            return .failure(.copyAttributeFailed(kAXFocusedWindowAttribute, focusedError))
        }

        return .failure(.missingFocusedWindow)
    }

    private func ancestorWindow(from element: AXUIElement) -> AXUIElement? {
        var current = element

        for _ in 0..<8 {
            let role = stringAttribute(current, kAXRoleAttribute)
            if role == kAXWindowRole {
                return current
            }

            var parentValue: CFTypeRef?
            let parentError = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue)
            guard parentError == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID()
            else {
                return nil
            }

            current = parentValue as! AXUIElement
        }

        return nil
    }

    private func setFrame(_ window: AXUIElement, to frame: CGRect) -> AXFrameWriteOutcome {
        var lastFrame = CGRect.null

        for _ in 0..<3 {
            switch setSize(frame.size, on: window) {
            case .success:
                break
            case .failure(let error):
                return .failed(error)
            }

            switch setPosition(frame.origin, on: window) {
            case .success:
                break
            case .failure(let error):
                return .failed(error)
            }

            switch focusedWindowFrame(window) {
            case .success(let actual):
                lastFrame = actual
                if framesApproximatelyMatch(actual, frame) {
                    return .converged(actual: actual)
                }
            case .failure(let error):
                return .failed(error)
            }
        }

        if lastFrame.isNull {
            switch focusedWindowFrame(window) {
            case .success(let actual):
                return frameWriteDidNotConverge(target: frame, actual: actual)
            case .failure(let error):
                return .failed(error)
            }
        }

        return frameWriteDidNotConverge(target: frame, actual: lastFrame)
    }

    private func frameWriteDidNotConverge(target: CGRect, actual: CGRect) -> AXFrameWriteOutcome {
        if let observed = inferObservedConstraints(target: target, actual: actual, tolerance: 2) {
            return .clamped(actual: actual, observed: observed)
        }
        return .failed(.frameDidNotConverge(target: target, actual: actual, attempts: 3))
    }

    private func setSize(_ targetSize: CGSize, on window: AXUIElement) -> Result<Void, AXClientError> {
        var size = targetSize
        guard let sizeValue = AXValueCreate(.cgSize, &size) else {
            return .failure(.sizeAttributeInvalid(kAXSizeAttribute, .failure))
        }
        let sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        guard sizeError == .success else {
            return .failure(.setAttributeFailed(kAXSizeAttribute, sizeError))
        }

        return .success(())
    }

    private func setPosition(_ point: CGPoint, on window: AXUIElement) -> Result<Void, AXClientError> {
        var origin = point
        guard let value = AXValueCreate(.cgPoint, &origin) else {
            return .failure(.pointAttributeInvalid(kAXPositionAttribute, .failure))
        }
        let positionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        guard positionError == .success else {
            return .failure(.setAttributeFailed(kAXPositionAttribute, positionError))
        }

        return .success(())
    }

    private func setBool(_ value: Bool, attribute: String, on window: AXUIElement) -> Result<Void, AXClientError> {
        let boolValue: CFBoolean = value ? kCFBooleanTrue! : kCFBooleanFalse!
        let error = AXUIElementSetAttributeValue(window, attribute as CFString, boolValue)
        guard error == .success else {
            return .failure(.setAttributeFailed(attribute, error))
        }
        return .success(())
    }

    private func windowElement(matching metadata: WindowMetadata) -> Result<AXUIElement, AXClientError> {
        guard let currentInfo = cgWindowInfo(matching: metadata.id, processID: metadata.pid) else {
            return .failure(.windowElementNotFound(metadata.id))
        }
        return windowElement(
            processID: metadata.pid,
            title: currentInfo.title,
            role: metadata.role,
            frame: currentInfo.frame,
            windowID: metadata.id
        )
    }

    private func isResizable(
        processID: pid_t,
        title: String,
        role: String,
        frame: CGRect,
        windowID: WindowID
    ) -> Bool {
        switch windowElement(processID: processID, title: title, role: role, frame: frame, windowID: windowID) {
        case .success(let element):
            return isResizable(element)
        case .failure:
            return false
        }
    }

    private func isResizable(_ window: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    private func windowElement(
        processID: pid_t,
        title expectedTitle: String,
        role expectedRole: String,
        frame expectedFrame: CGRect,
        windowID: WindowID
    ) -> Result<AXUIElement, AXClientError> {
        let app = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success else {
            return .failure(.windowsAttributeInvalid(processID, error))
        }
        guard let windows = value as? [AXUIElement] else {
            return .failure(.windowsAttributeInvalid(processID, error))
        }

        for window in windows {
            let title = stringAttribute(window, kAXTitleAttribute)
            let role = stringAttribute(window, kAXRoleAttribute)
            guard expectedTitle.isEmpty || title.isEmpty || title == expectedTitle else { continue }
            guard expectedRole.isEmpty || role.isEmpty || role == expectedRole else { continue }

            switch focusedWindowFrame(window) {
            case .success(let frame) where framesApproximatelyMatch(frame, expectedFrame):
                return .success(window)
            case .success:
                continue
            case .failure:
                continue
            }
        }

        return .failure(.windowElementNotFound(windowID))
    }

    private func cgWindowInfo(matching id: WindowID, processID: pid_t) -> (title: String, frame: CGRect)? {
        guard processID != inventoryFilter.currentProcessID else { return nil }
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return nil
        }

        for window in windows {
            guard
                let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == processID,
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let number = window[kCGWindowNumber as String] as? CGWindowID,
                number == id.raw,
                let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                continue
            }

            return (window[kCGWindowName as String] as? String ?? "", bounds)
        }

        return nil
    }

    private func focusedWindowFrame(_ window: AXUIElement) -> Result<CGRect, AXClientError> {
        let position: CGPoint
        switch pointAttribute(window, kAXPositionAttribute) {
        case .success(let value):
            position = value
        case .failure(let error):
            return .failure(error)
        }

        let size: CGSize
        switch sizeAttribute(window, kAXSizeAttribute) {
        case .success(let value):
            size = value
        case .failure(let error):
            return .failure(error)
        }

        return .success(CGRect(origin: position, size: size))
    }

    private func stringAttribute(_ window: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }

    private func boolAttribute(_ window: AXUIElement, _ attribute: String, defaultValue: Bool) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success else {
            return defaultValue
        }
        return value as? Bool ?? defaultValue
    }

    private func pointAttribute(_ window: AXUIElement, _ attribute: String) -> Result<CGPoint, AXClientError> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return .failure(.pointAttributeInvalid(attribute, error))
        }

        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            return .failure(.pointAttributeInvalid(attribute, error))
        }
        return .success(point)
    }

    private func sizeAttribute(_ window: AXUIElement, _ attribute: String) -> Result<CGSize, AXClientError> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return .failure(.sizeAttributeInvalid(attribute, error))
        }

        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return .failure(.sizeAttributeInvalid(attribute, error))
        }
        return .success(size)
    }

    private func matchedWindowID(processID: pid_t, title: String, frame: CGRect) -> WindowID? {
        guard processID != inventoryFilter.currentProcessID else { return nil }
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return nil
        }

        for window in windows {
            guard
                let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == processID,
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let number = window[kCGWindowNumber as String] as? CGWindowID,
                let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                framesApproximatelyMatch(bounds, frame)
            else {
                continue
            }

            let windowName = window[kCGWindowName as String] as? String ?? ""
            guard title.isEmpty || windowName.isEmpty || title == windowName else {
                continue
            }

            return WindowID(raw: number)
        }

        return nil
    }

    private func framesApproximatelyMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= 2
            && abs(lhs.origin.y - rhs.origin.y) <= 2
            && abs(lhs.size.width - rhs.size.width) <= 2
            && abs(lhs.size.height - rhs.size.height) <= 2
    }
}
