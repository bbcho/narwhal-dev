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
    case windowNotRaised(WindowID, blocker: WindowID?)

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
        case .windowNotRaised(let windowID, let blocker):
            if let blocker {
                return "\(windowID.description) was not raised above overlapping window \(blocker.description)"
            }
            return "\(windowID.description) was not visible after raise"
        }
    }
}

enum AXFrameWriteOutcome: Sendable {
    case converged(actual: CGRect)
    case clamped(actual: CGRect, observed: WindowConstraints)
    case failed(AXClientError)
}

enum AXSettleStrategy: Sendable {
    case suspending
    case servicingRunLoop
}

enum AXFrameWriteOrder: Equatable {
    case sizeThenPosition
    case positionThenSize
}

func axFrameWriteOrder(
    current: CGRect?,
    target: CGRect,
    tolerance: CGFloat = frameWriteSettleTolerance
) -> AXFrameWriteOrder {
    guard let current else { return .sizeThenPosition }
    let shrinksWidth = target.width < current.width - tolerance
    let shrinksHeight = target.height < current.height - tolerance
    guard !shrinksWidth, !shrinksHeight else { return .sizeThenPosition }

    let expandsLeft = target.width > current.width + tolerance
        && target.minX < current.minX - tolerance
    let expandsUp = target.height > current.height + tolerance
        && target.minY < current.minY - tolerance
    return expandsLeft || expandsUp ? .positionThenSize : .sizeThenPosition
}

func confirmedObservedConstraints(
    target: CGRect,
    actualFrames: [CGRect],
    tolerance: CGFloat = frameWriteSettleTolerance
) -> WindowConstraints? {
    guard actualFrames.count >= 2,
          let previous = actualFrames.dropLast().last,
          let actual = actualFrames.last,
          previous.narwhalApproximatelyEquals(actual, tolerance: tolerance)
    else { return nil }
    return inferObservedConstraints(
        target: target,
        actual: actual,
        tolerance: Double(tolerance)
    )
}

@MainActor
private struct CoordinatedFrameWrite {
    let windowID: WindowID
    let element: AXUIElement
    let target: CGRect
    var observedFrames: [CGRect]
    var positionFirst: Bool
}

struct AXClient {
    private let inventoryFilter: WindowInventoryFilter
    private let settleStrategy: AXSettleStrategy
    private let runtimeMetrics: RuntimeMetrics?
    private static let messagingTimeout: Float = 1.0
    private static let frameWriteSettleInterval: TimeInterval = 0.08
    private static let constraintConfirmationInterval: TimeInterval = 0.20

    init(
        processID: pid_t = getpid(),
        settleStrategy: AXSettleStrategy = .suspending,
        runtimeMetrics: RuntimeMetrics? = nil
    ) {
        inventoryFilter = WindowInventoryFilter(currentProcessID: processID)
        self.settleStrategy = settleStrategy
        self.runtimeMetrics = runtimeMetrics
    }

    private static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func systemWideElement() -> AXUIElement {
        bounded(AXUIElementCreateSystemWide())
    }

    private static func applicationElement(processID: pid_t) -> AXUIElement {
        bounded(AXUIElementCreateApplication(processID))
    }

    func windowSnapshot() -> AXWindowSnapshot {
        let metricInterval = runtimeMetrics?.begin(.windowSnapshot)
        defer { runtimeMetrics?.end(metricInterval) }
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return AXWindowSnapshot(
                windows: [],
                quality: .unavailable(AXClientError.visibleWindowListUnavailable.description)
            )
        }

        let inventory = inventoryFilter.read(windows)
        let metadata = inventory.records.map(windowMetadata(from:))
            .sorted { $0.id.raw < $1.id.raw }
        let quality: AXSnapshotQuality = inventory.errors.isEmpty
            ? .complete
            : .partial(inventory.errors)
        return AXWindowSnapshot(windows: metadata, quality: quality)
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

    private func raisedVisibilityDecision(for target: WindowID) -> Result<WindowStackVisibilityDecision, AXClientError> {
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return .failure(.visibleWindowListUnavailable)
        }

        let entries: [WindowStackEntry] = windows.compactMap { window in
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
            return WindowStackEntry(id: WindowID(raw: number), frame: frame)
        }

        return .success(windowStackVisibility(target: target, frontToBackWindows: entries))
    }

    private func windowMetadata(from window: WindowInventoryRecord) -> WindowMetadata {
        return WindowMetadata(
            id: window.id,
            bundleID: BundleID(raw: NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier ?? ""),
            title: window.title,
            role: kAXWindowRole,
            pid: window.ownerPID,
            frame: window.frame,
            isResizable: isResizable(
                processID: window.ownerPID,
                title: window.title,
                role: kAXWindowRole,
                frame: window.frame,
                windowID: window.id
            ),
            isMinimized: false
        )
    }

    func focusedWindowSnapshot() -> Result<FocusedWindowSnapshot, AXClientError> {
        let metricInterval = runtimeMetrics?.begin(.focusedWindowSnapshot)
        defer { runtimeMetrics?.end(metricInterval) }
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
                isResizable: isResizeEligible(
                    focusedWindow,
                    role: role,
                    subrole: subrole,
                    frame: frame,
                    isMinimized: isMinimized,
                    isFullscreen: isFullscreen
                ),
                isMinimized: isMinimized,
                isFullscreen: isFullscreen
            ))
        case .failure(let error):
            return .failure(error)
        }
    }

#if NARWHAL_ENABLE_VERIFIERS
    func debugFocusedWindowRelationships() -> String {
        let system = Self.systemWideElement()
        let focusedUI = elementAttribute(system, kAXFocusedUIElementAttribute)
        let focusedApp = try? focusedApplicationElement(from: system).get()
        let rawFocusedWindow = focusedApp.flatMap { elementAttribute($0, kAXFocusedWindowAttribute) }
        let parts = [
            "focusedUI=\(focusedUI.map(debugElement) ?? "nil")",
            "uiWindow=\(focusedUI.flatMap { elementAttribute($0, kAXWindowAttribute) }.map(debugElement) ?? "nil")",
            "focusedWindow=\(rawFocusedWindow.map(debugElement) ?? "nil")",
            "focusedSheets=\(rawFocusedWindow.map { debugElements(arrayAttribute($0, "AXSheets")) } ?? "nil")",
            "focusedChildren=\(rawFocusedWindow.map { debugElements(arrayAttribute($0, kAXChildrenAttribute)) } ?? "nil")",
            "appWindows=\(focusedApp.map { debugElements(arrayAttribute($0, kAXWindowsAttribute)) } ?? "nil")"
        ]
        return parts.joined(separator: " ")
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return Self.bounded(value as! AXUIElement)
    }

    private func arrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let elements = value as? [AXUIElement] else { return [] }
        return elements.map(Self.bounded)
    }

    private func debugElements(_ elements: [AXUIElement]) -> String {
        "[" + elements.map(debugElement).joined(separator: ",") + "]"
    }

    private func debugElement(_ element: AXUIElement) -> String {
        "\(stringAttribute(element, kAXRoleAttribute))/\(stringAttribute(element, kAXSubroleAttribute))/\(stringAttribute(element, kAXTitleAttribute))"
    }
#endif

    @MainActor
    func setFocusedWindowFrame(_ frame: CGRect) async -> AXFrameWriteOutcome {
        switch focusedWindowElement() {
        case .success(let window):
            return await setFrame(window, to: frame)
        case .failure(let error):
            return .failed(error)
        }
    }

    @MainActor
    func setFrame(_ window: WindowMetadata, to frame: CGRect) async -> AXFrameWriteOutcome {
        switch await windowElement(matching: window) {
        case .success(let element):
            return await setFrame(element, to: frame)
        case .failure(let error):
            return .failed(error)
        }
    }

    @MainActor
    func setFramesCoordinated(
        _ requests: [(window: WindowMetadata, frame: CGRect)]
    ) async -> [WindowID: AXFrameWriteOutcome] {
        let metricInterval = runtimeMetrics?.begin(.coordinatedFrameWrite)
        defer { runtimeMetrics?.end(metricInterval) }
        var outcomes: [WindowID: AXFrameWriteOutcome] = [:]
        var pending: [CoordinatedFrameWrite] = []

        for request in requests {
            switch await windowElement(matching: request.window) {
            case .success(let element):
                pending.append(CoordinatedFrameWrite(
                    windowID: request.window.id,
                    element: element,
                    target: request.frame,
                    observedFrames: [],
                    positionFirst: false
                ))
            case .failure(let error):
                outcomes[request.window.id] = .failed(error)
            }
        }

        for _ in 0..<3 where !pending.isEmpty {
            var ready: [CoordinatedFrameWrite] = []
            for var write in pending {
                switch focusedWindowFrame(write.element) {
                case .success(let current):
                    if current.narwhalApproximatelyEquals(write.target, tolerance: frameWriteSettleTolerance) {
                        outcomes[write.windowID] = .converged(actual: current)
                        continue
                    }
                    write.positionFirst = axFrameWriteOrder(current: current, target: write.target) == .positionThenSize
                case .failure:
                    write.positionFirst = false
                }
                ready.append(write)
            }
            pending = ready
            guard !pending.isEmpty else { break }

            var didWritePositionFirst = false
            pending = pending.filter { write in
                guard write.positionFirst else { return true }
                switch setPosition(write.target.origin, on: write.element) {
                case .success:
                    didWritePositionFirst = true
                    return true
                case .failure(let error):
                    outcomes[write.windowID] = .failed(error)
                    return false
                }
            }
            if didWritePositionFirst {
                await settle(for: Self.frameWriteSettleInterval)
            }
            guard !pending.isEmpty else { break }

            var didWriteSize = false
            pending = pending.filter { write in
                switch setSize(write.target.size, on: write.element) {
                case .success:
                    didWriteSize = true
                    return true
                case .failure(let error):
                    outcomes[write.windowID] = .failed(error)
                    return false
                }
            }
            if didWriteSize {
                await settle(for: Self.frameWriteSettleInterval)
            }
            guard !pending.isEmpty else { break }

            var didWritePosition = false
            pending = pending.filter { write in
                switch setPosition(write.target.origin, on: write.element) {
                case .success:
                    didWritePosition = true
                    return true
                case .failure(let error):
                    outcomes[write.windowID] = .failed(error)
                    return false
                }
            }
            if didWritePosition {
                await settle(for: Self.frameWriteSettleInterval)
            }

            var unsettled: [CoordinatedFrameWrite] = []
            for var write in pending {
                switch focusedWindowFrame(write.element) {
                case .success(let actual):
                    if actual.narwhalApproximatelyEquals(write.target, tolerance: frameWriteSettleTolerance) {
                        outcomes[write.windowID] = .converged(actual: actual)
                    } else {
                        write.observedFrames.append(actual)
                        unsettled.append(write)
                    }
                case .failure(let error):
                    outcomes[write.windowID] = .failed(error)
                }
            }
            pending = unsettled
        }

        if !pending.isEmpty {
            await settle(for: Self.constraintConfirmationInterval)
        }
        for var write in pending {
            switch focusedWindowFrame(write.element) {
            case .success(let actual):
                if actual.narwhalApproximatelyEquals(write.target, tolerance: frameWriteSettleTolerance) {
                    outcomes[write.windowID] = .converged(actual: actual)
                } else {
                    write.observedFrames.append(actual)
                    outcomes[write.windowID] = frameWriteDidNotConverge(
                        target: write.target,
                        actualFrames: write.observedFrames
                    )
                }
            case .failure(let error):
                outcomes[write.windowID] = .failed(error)
            }
        }

        return outcomes
    }

    @MainActor
    func frame(of window: WindowMetadata) async -> Result<CGRect, AXClientError> {
        switch await windowElement(matching: window) {
        case .success(let element):
            return focusedWindowFrame(element)
        case .failure(let error):
            return .failure(error)
        }
    }

    @MainActor
    func closeWindow(_ window: WindowMetadata) async -> Result<Void, AXClientError> {
        switch await windowElement(matching: window) {
        case .success(let element):
            var closeButtonValue: CFTypeRef?
            let copyError = AXUIElementCopyAttributeValue(
                element,
                kAXCloseButtonAttribute as CFString,
                &closeButtonValue
            )
            guard copyError == .success,
                  let closeButtonValue,
                  CFGetTypeID(closeButtonValue) == AXUIElementGetTypeID()
            else {
                return .failure(.copyAttributeFailed(kAXCloseButtonAttribute, copyError))
            }

            let closeButton = Self.bounded(closeButtonValue as! AXUIElement)
            let error = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            guard error == .success else {
                return .failure(.performActionFailed(kAXPressAction, error))
            }
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    @MainActor
    func focusWindow(_ window: WindowMetadata) async -> Result<Void, AXClientError> {
        guard await activateApplication(processID: window.pid) else {
            return .failure(.applicationActivateFailed(window.pid))
        }

        let element: AXUIElement
        switch await windowElement(matching: window) {
        case .success(let value):
            element = value
        case .failure(let error):
            return .failure(error)
        }

        let application = Self.applicationElement(processID: window.pid)
        var lastRaiseError: AXError?
        var lastFocusError: AXClientError?
        var lastVisibilityDecision: WindowStackVisibilityDecision?
        for _ in 0..<3 {
            switch bringApplicationForward(application) {
            case .success:
                break
            case .failure(let error):
                lastFocusError = error
            }

            switch setFocused(element, in: application) {
            case .success:
                break
            case .failure(let error):
                lastFocusError = error
            }

            let raiseError = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            guard raiseError == .success else {
                lastRaiseError = raiseError
                continue
            }

            await settle(for: 0.04)
            switch raisedVisibilityDecision(for: window.id) {
            case .success(.visible):
                return .success(())
            case .success(let decision):
                lastVisibilityDecision = decision
            case .failure(let error):
                return .failure(error)
            }
        }

        if let lastRaiseError {
            return .failure(.performActionFailed(kAXRaiseAction, lastRaiseError))
        }
        if case .blockedBy(let blocker) = lastVisibilityDecision {
            return .failure(.windowNotRaised(window.id, blocker: blocker))
        }
        if case .targetMissing = lastVisibilityDecision {
            return .failure(.windowNotRaised(window.id, blocker: nil))
        }
        if let lastFocusError {
            return .failure(lastFocusError)
        }
        return .failure(.windowNotRaised(window.id, blocker: nil))
    }

    @MainActor
    private func activateApplication(processID: pid_t) async -> Bool {
        if processID == getpid() {
            NSApp.activate(ignoringOtherApps: true)
            await settle(for: 0.04)
            return true
        }
        return NSRunningApplication(processIdentifier: processID)?.activate(options: []) == true
    }

    private func bringApplicationForward(_ application: AXUIElement) -> Result<Void, AXClientError> {
        setBool(true, attribute: kAXFrontmostAttribute, on: application)
    }

    private func setFocused(_ element: AXUIElement, in application: AXUIElement) -> Result<Void, AXClientError> {
        var firstError: AXClientError?
        var didSetFocus = false

        let appFocusedWindowError = AXUIElementSetAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            element
        )
        if appFocusedWindowError == .success {
            didSetFocus = true
        } else {
            firstError = .setAttributeFailed(kAXFocusedWindowAttribute, appFocusedWindowError)
        }

        switch setBool(true, attribute: kAXMainAttribute, on: element) {
        case .success:
            didSetFocus = true
        case .failure(let error):
            firstError = firstError ?? error
        }

        switch setBool(true, attribute: kAXFocusedAttribute, on: element) {
        case .success:
            didSetFocus = true
        case .failure(let error):
            firstError = firstError ?? error
        }

        if didSetFocus {
            return .success(())
        }
        return .failure(firstError ?? .missingFocusedWindow)
    }

    private func focusedWindowElement() -> Result<AXUIElement, AXClientError> {
        let systemElement = Self.systemWideElement()
        let focusedUIWindow = focusedUIElementWindow(from: systemElement)

        let focusedApp: AXUIElement
        let focusedAppError: AXClientError?
        switch focusedApplicationElement(from: systemElement) {
        case .success(let app):
            focusedApp = app
            focusedAppError = nil
        case .failure(let error):
            if let app = frontmostApplicationElement() {
                focusedApp = app
                focusedAppError = error
            } else if let focusedUIWindow {
                return .success(focusedUIWindow)
            } else {
                return .failure(error)
            }
        }

        switch focusedWindowElement(in: focusedApp) {
        case .success(let window):
            if isTransientFocusedWindow(
                role: stringAttribute(window, kAXRoleAttribute),
                subrole: stringAttribute(window, kAXSubroleAttribute)
            ) || focusedUIWindow == nil {
                return .success(window)
            }
            return .success(focusedUIWindow ?? window)
        case .failure(let focusedWindowError):
            if let focusedUIWindow {
                return .success(focusedUIWindow)
            }
            if let focusedAppError {
                return .failure(focusedAppError)
            }
            return .failure(focusedWindowError)
        }
    }

    private func focusedApplicationElement(from systemElement: AXUIElement) -> Result<AXUIElement, AXClientError> {
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

        return .success(Self.bounded(focusedAppValue as! AXUIElement))
    }

    private func focusedWindowElement(in focusedApp: AXUIElement) -> Result<AXUIElement, AXClientError> {
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            focusedApp,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        )
        if focusedError == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            let focusedWindow = Self.bounded(focusedValue as! AXUIElement)
            return .success(deepestAttachedSheet(from: focusedWindow) ?? focusedWindow)
        }

        if focusedError != .success {
            return .failure(.copyAttributeFailed(kAXFocusedWindowAttribute, focusedError))
        }

        return .failure(.missingFocusedWindow)
    }

    private func focusedUIElementWindow(from systemElement: AXUIElement) -> AXUIElement? {
        var focusedElementValue: CFTypeRef?
        let elementError = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        if elementError == .success,
           let focusedElementValue,
           CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() {
            let focusedElement = Self.bounded(focusedElementValue as! AXUIElement)
            if let window = containingWindow(from: focusedElement) {
                return deepestAttachedSheet(from: window) ?? window
            }
        }

        return nil
    }

    private func deepestAttachedSheet(from window: AXUIElement) -> AXUIElement? {
        var current = window
        var deepest: AXUIElement?

        for _ in 0..<4 {
            var sheetsValue: CFTypeRef?
            let sheetsError = AXUIElementCopyAttributeValue(
                current,
                "AXSheets" as CFString,
                &sheetsValue
            )
            guard sheetsError == .success,
                  let sheets = sheetsValue as? [AXUIElement],
                  let sheet = sheets.last
            else { break }
            let boundedSheet = Self.bounded(sheet)
            deepest = boundedSheet
            current = boundedSheet
        }

        return deepest
    }

    private func containingWindow(from element: AXUIElement) -> AXUIElement? {
        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        if isFocusedWindowContainer(role: role, subrole: subrole) {
            return element
        }

        var windowValue: CFTypeRef?
        let windowError = AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowValue
        )
        if windowError == .success,
           let windowValue,
           CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            let window = Self.bounded(windowValue as! AXUIElement)
            if isFocusedWindowContainer(
                role: stringAttribute(window, kAXRoleAttribute),
                subrole: stringAttribute(window, kAXSubroleAttribute)
            ) {
                return window
            }
        }

        return ancestorWindow(from: element)
    }

    private func frontmostApplicationElement() -> AXUIElement? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        return Self.applicationElement(processID: frontmost.processIdentifier)
    }

    private func ancestorWindow(from element: AXUIElement) -> AXUIElement? {
        var current = element

        for _ in 0..<8 {
            let role = stringAttribute(current, kAXRoleAttribute)
            let subrole = stringAttribute(current, kAXSubroleAttribute)
            if isFocusedWindowContainer(role: role, subrole: subrole) {
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

            current = Self.bounded(parentValue as! AXUIElement)
        }

        return nil
    }

    @MainActor
    private func setFrame(_ window: AXUIElement, to frame: CGRect) async -> AXFrameWriteOutcome {
        var observedFrames: [CGRect] = []

        for _ in 0..<3 {
            let currentFrame: CGRect?
            switch focusedWindowFrame(window) {
            case .success(let current):
                currentFrame = current
            case .failure:
                currentFrame = nil
            }

            let positionFirst = axFrameWriteOrder(current: currentFrame, target: frame) == .positionThenSize

            if positionFirst {
                switch setPosition(frame.origin, on: window) {
                case .success:
                    await settle(for: Self.frameWriteSettleInterval)
                case .failure(let error):
                    return .failed(error)
                }
            }

            switch setSize(frame.size, on: window) {
            case .success:
                await settle(for: Self.frameWriteSettleInterval)
            case .failure(let error):
                return .failed(error)
            }

            switch setPosition(frame.origin, on: window) {
            case .success:
                await settle(for: Self.frameWriteSettleInterval)
            case .failure(let error):
                return .failed(error)
            }

            switch focusedWindowFrame(window) {
            case .success(let actual):
                if actual.narwhalApproximatelyEquals(frame, tolerance: frameWriteSettleTolerance) {
                    return .converged(actual: actual)
                }
                observedFrames.append(actual)
            case .failure(let error):
                return .failed(error)
            }
        }

        await settle(for: Self.constraintConfirmationInterval)
        switch focusedWindowFrame(window) {
        case .success(let actual):
            if actual.narwhalApproximatelyEquals(frame, tolerance: frameWriteSettleTolerance) {
                return .converged(actual: actual)
            }
            observedFrames.append(actual)
            return frameWriteDidNotConverge(target: frame, actualFrames: observedFrames)
        case .failure(let error):
            return .failed(error)
        }
    }

    private func frameWriteDidNotConverge(target: CGRect, actualFrames: [CGRect]) -> AXFrameWriteOutcome {
        guard let actual = actualFrames.last else {
            return .failed(.frameDidNotConverge(target: target, actual: .null, attempts: 0))
        }
        if let observed = confirmedObservedConstraints(
            target: target,
            actualFrames: actualFrames
        ) {
            return .clamped(actual: actual, observed: observed)
        }
        return .failed(.frameDidNotConverge(target: target, actual: actual, attempts: actualFrames.count))
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

    @MainActor
    private func windowElement(matching metadata: WindowMetadata) async -> Result<AXUIElement, AXClientError> {
        var expectedTitle = metadata.title
        var expectedFrame = metadata.frame

        for attempt in 0..<5 {
            if let currentInfo = cgWindowInfo(matching: metadata.id, processID: metadata.pid) {
                expectedTitle = currentInfo.title
                expectedFrame = currentInfo.frame
            }

            switch windowElement(
                processID: metadata.pid,
                title: expectedTitle,
                role: metadata.role,
                frame: expectedFrame,
                windowID: metadata.id
            ) {
            case .success(let element):
                return .success(element)
            case .failure where attempt < 4:
                await settle(for: 0.05)
            case .failure(let error):
                return .failure(error)
            }
        }

        return .failure(.windowElementNotFound(metadata.id))
    }

    @MainActor
    private func settle(for interval: TimeInterval) async {
        switch settleStrategy {
        case .suspending:
            let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        case .servicingRunLoop:
            serviceRunLoop(for: interval)
        }
    }

    @MainActor
    private func serviceRunLoop(for interval: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(max(0, interval)))
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
            return isResizeEligible(element, fallbackRole: role, frame: frame)
        case .failure:
            return windowResizeEligibility(WindowResizeEligibilityTraits(
                role: role,
                subrole: "",
                axSizeAttributeSettable: false,
                isMinimized: false,
                isFullscreen: false,
                frame: frame
            ))
        }
    }

    private func isResizeEligible(
        _ window: AXUIElement,
        fallbackRole: String = "",
        frame fallbackFrame: CGRect
    ) -> Bool {
        let role = stringAttribute(window, kAXRoleAttribute)
        let frame: CGRect
        switch focusedWindowFrame(window) {
        case .success(let value):
            frame = value
        case .failure:
            frame = fallbackFrame
        }
        return isResizeEligible(
            window,
            role: role.isEmpty ? fallbackRole : role,
            subrole: stringAttribute(window, kAXSubroleAttribute),
            frame: frame,
            isMinimized: boolAttribute(window, kAXMinimizedAttribute, defaultValue: false),
            isFullscreen: boolAttribute(window, "AXFullScreen", defaultValue: false)
        )
    }

    private func isResizeEligible(
        _ window: AXUIElement,
        role: String,
        subrole: String,
        frame: CGRect,
        isMinimized: Bool,
        isFullscreen: Bool
    ) -> Bool {
        windowResizeEligibility(WindowResizeEligibilityTraits(
            role: role,
            subrole: subrole,
            axSizeAttributeSettable: isSizeAttributeSettable(window),
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            frame: frame
        ))
    }

    private func isSizeAttributeSettable(_ window: AXUIElement) -> Bool {
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
        let app = Self.applicationElement(processID: processID)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success else {
            return .failure(.windowsAttributeInvalid(processID, error))
        }
        guard let windows = value as? [AXUIElement] else {
            return .failure(.windowsAttributeInvalid(processID, error))
        }

        var candidates: [(element: AXUIElement, frame: CGRect)] = []
        for rawWindow in windows {
            let window = Self.bounded(rawWindow)
            let title = stringAttribute(window, kAXTitleAttribute)
            let role = stringAttribute(window, kAXRoleAttribute)
            guard expectedTitle.isEmpty || title.isEmpty || title == expectedTitle else { continue }
            guard expectedRole.isEmpty || role.isEmpty || role == expectedRole else { continue }

            switch focusedWindowFrame(window) {
            case .success(let frame) where frame.narwhalApproximatelyEquals(
                expectedFrame,
                tolerance: frameWriteSettleTolerance
            ):
                return .success(window)
            case .success(let frame):
                candidates.append((element: window, frame: frame))
            case .failure:
                continue
            }
        }

        if candidates.count == 1, let candidate = candidates.first {
            return .success(candidate.element)
        }

        let closest = candidates
            .map { candidate in
                (element: candidate.element, frame: candidate.frame, distance: frameDistance(candidate.frame, expectedFrame))
            }
            .min { $0.distance < $1.distance }
        if let closest,
           closest.distance <= 160 || framesOverlapSubstantially(closest.frame, expectedFrame) {
            return .success(closest.element)
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
                bounds.narwhalApproximatelyEquals(frame, tolerance: frameWriteSettleTolerance)
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

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    private func framesOverlapSubstantially(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        guard lhs.width > 0,
              lhs.height > 0,
              rhs.width > 0,
              rhs.height > 0
        else { return false }
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isInfinite else { return false }
        let overlapArea = max(0, intersection.width) * max(0, intersection.height)
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        return smallerArea > 0 && overlapArea / smallerArea >= 0.65
    }
}
