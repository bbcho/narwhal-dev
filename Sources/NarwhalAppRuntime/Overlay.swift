import AppKit
import Darwin
import NarwhalAppSupport
import NarwhalCore

// WindowServer can acknowledge cross-process ordering without applying it for
// ad-hoc-signed apps. Ordering is best-effort; the visibility pass below hides a
// tiled border whenever a foreign window obscures its target.
private typealias CGSConnectionIDFunc = @convention(c) () -> Int32
private typealias CGSOrderWindowFunc = @convention(c) (Int32, UInt32, Int32, UInt32) -> Int32

private let overlayCGSHandle = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    RTLD_LAZY
)

private func loadOverlayCGS<T>(_ name: String, as type: T.Type) -> T? {
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
        return unsafeBitCast(symbol, to: type)
    }
    if let overlayCGSHandle, let symbol = dlsym(overlayCGSHandle, name) {
        return unsafeBitCast(symbol, to: type)
    }
    return nil
}

// SkyLight renamed CGS* to SLS* in macOS 10.15+. The legacy CGS* symbols are
// kept as stubs in some macOS versions and may silently no-op for foreign
// windows, so prefer SLS* first.
private let cgsMainConnectionID: CGSConnectionIDFunc? =
    loadOverlayCGS("SLSMainConnectionID", as: CGSConnectionIDFunc.self)
    ?? loadOverlayCGS("CGSMainConnectionID", as: CGSConnectionIDFunc.self)
    ?? loadOverlayCGS("_CGSDefaultConnection", as: CGSConnectionIDFunc.self)
private let cgsOrderWindow: CGSOrderWindowFunc? =
    loadOverlayCGS("SLSOrderWindow", as: CGSOrderWindowFunc.self)
    ?? loadOverlayCGS("CGSOrderWindow", as: CGSOrderWindowFunc.self)

private let kCGSOrderAbove: Int32 = 1
private let kCGSOrderBelow: Int32 = -1

enum OverlayTone {
    case info
    case success
    case warning
    case error
}

enum CommandOverlayScrollDirection {
    case up
    case down
}

struct OverlayRenderResult: Equatable, Sendable {
    let staleTiledBorderTargets: [WindowID]
}

private struct OverlayWindowEntry {
    let cgID: CGWindowID
    let frame: CGRect

    var stackEntry: WindowStackEntry {
        WindowStackEntry(id: WindowID(raw: cgID), frame: frame)
    }
}

@MainActor
final class Overlay {
    private static let tiledBorderConfig = BorderConfig(width: 2, colorHex: "#30D158")

    private var borderConfig: BorderConfig
    private var hudConfig: HUDConfig
    private var borderWindow: NSWindow?
    private var borderView: BorderView?
    private var tiledBorderWindows: [WindowID: NSWindow] = [:]
    private var tiledBorderViews: [WindowID: BorderView] = [:]
    private var commandWindow: NSWindow?
    private var hudWindow: NSWindow?
    private var hudHideTask: Task<Void, Never>?
    private var dragPreviewWindow: NSWindow?
    private var dragPreviewView: DragPreviewView?
    private var focusBorderSuppression: FocusBorderSuppression?
    private var focusBorderRestackTimers: [Timer] = []
    private var visibleWindowID: WindowID?

    init(border: BorderConfig, hud: HUDConfig) {
        self.borderConfig = border
        self.hudConfig = hud
    }

    func updateConfig(border: BorderConfig, hud: HUDConfig) {
        borderConfig = border
        hudConfig = hud
        borderView?.update(border: border)
    }

    func suppressFocusBorder(for windowID: WindowID, frame: CGRect) {
        focusBorderSuppression = FocusBorderSuppression(windowID: windowID, frame: frame)
        hideFocusBorder()
    }

    @discardableResult
    func render(_ model: OverlayModel) -> OverlayRenderResult {
        let staleTiledBorderTargets = renderTiledBorders(model.tiledBorders)
        if let focusBorder = model.focusBorder {
            showFocusBorder(focusBorder)
            enforceFocusBorderObscurationVisibility(
                target: focusBorder,
                entries: currentOverlayWindowEntries()
            )
        } else {
            hideFocusBorder()
        }
        return OverlayRenderResult(staleTiledBorderTargets: staleTiledBorderTargets)
    }

    private func renderTiledBorders(_ targets: [FocusBorderTarget]) -> [WindowID] {
        let nextIDs = Set(targets.map(\.windowID))
        for windowID in Array(tiledBorderWindows.keys) where !nextIDs.contains(windowID) {
            hideTiledBorder(windowID)
        }

        let liveWindowEntries = currentOverlayWindowEntries()
        let liveStackEntries = liveWindowEntries?.map(\.stackEntry)
        var staleTargets: [WindowID] = []
        for target in targets.sorted(by: { $0.windowID.raw < $1.windowID.raw }) {
            if showTiledBorder(target, liveWindows: liveStackEntries) {
                staleTargets.append(target.windowID)
            }
        }
        // Cross-process window ordering is unreliable on macOS 15+ for
        // ad-hoc-signed apps (SLSOrderWindow returns success but no-ops). To
        // guarantee borders never appear above unrelated windows, hide any
        // border whose tile is currently obscured by a foreign window above it.
        if let liveWindowEntries {
            enforceTiledBorderObscurationVisibility(targets: targets, entries: liveWindowEntries)
        }
        return staleTargets
    }

    private func enforceTiledBorderObscurationVisibility(targets: [FocusBorderTarget], entries: [OverlayWindowEntry]) {
        let tileIDs = Set(targets.map(\.windowID.raw))
        let overlayWindowNumbers = ownOverlayWindowNumbers()

        for target in targets {
            guard let borderWindow = tiledBorderWindows[target.windowID] else { continue }
            let tileFrame = appKitFrame(forAXFrame: target.frame)
            guard let tileIndex = entries.firstIndex(where: { $0.cgID == target.windowID.raw }) else {
                if borderWindow.isVisible { borderWindow.orderOut(nil) }
                continue
            }
            var obscured = false
            for above in entries[0..<tileIndex] {
                if overlayWindowNumbers.contains(above.cgID) { continue }
                if tileIDs.contains(above.cgID) { continue }
                if appKitFrame(forAXFrame: above.frame).intersects(tileFrame) {
                    obscured = true
                    break
                }
            }
            // Use alphaValue, not orderOut: ordering out releases the WindowServer
            // number, and ordering front creates a new top-level window that can
            // leave an orphan border in the CG list. Alpha preserves its identity.
            borderWindow.alphaValue = obscured ? 0.0 : 1.0
        }
    }

    private func enforceFocusBorderObscurationVisibility(
        target: FocusBorderTarget,
        entries: [OverlayWindowEntry]?
    ) {
        guard let borderWindow, let entries else { return }
        let overlayWindowNumbers = ownOverlayWindowNumbers()
        let targetFrame = appKitFrame(forAXFrame: target.frame)
        guard let targetIndex = entries.firstIndex(where: { $0.cgID == target.windowID.raw }) else {
            borderWindow.alphaValue = 0
            return
        }
        let isObscured = entries[0..<targetIndex].contains { entry in
            !overlayWindowNumbers.contains(entry.cgID)
                && appKitFrame(forAXFrame: entry.frame).intersects(targetFrame)
        }
        borderWindow.alphaValue = isObscured ? 0 : 1
    }

    private func ownOverlayWindowNumbers() -> Set<CGWindowID> {
        let windows = [borderWindow, commandWindow, hudWindow, dragPreviewWindow]
            + Array(tiledBorderWindows.values)
        return Set(windows.compactMap { window -> CGWindowID? in
            guard let number = window?.windowNumber, number > 0 else { return nil }
            return CGWindowID(number)
        })
    }

#if NARWHAL_ENABLE_VERIFIERS
    func debugFocusBorderWindowID() -> WindowID? {
        visibleWindowID
    }

    func debugFocusBorderIsVisible() -> Bool {
        borderWindow?.isVisible == true
    }

    func debugFocusBorderIsVisuallyVisible() -> Bool {
        borderWindow?.isVisible == true && (borderWindow?.alphaValue ?? 0) > 0
    }

    func debugFocusBorderWindowNumber() -> Int? {
        borderWindow?.windowNumber
    }

    func debugFocusBorderFrame() -> CGRect? {
        borderWindow?.frame
    }

    func debugFocusBorderLevelRawValue() -> Int? {
        borderWindow?.level.rawValue
    }

    func debugTiledBorderWindowIDs() -> [WindowID] {
        tiledBorderWindows.keys.sorted { $0.raw < $1.raw }
    }

    func debugVisibleTiledBorderCount() -> Int {
        tiledBorderWindows.values.filter(\.isVisible).count
    }

    func debugTiledBorderFrame(for windowID: WindowID) -> CGRect? {
        tiledBorderWindows[windowID]?.frame
    }

    func debugTiledBorderWindowNumber(for windowID: WindowID) -> Int? {
        tiledBorderWindows[windowID]?.windowNumber
    }

    func debugTiledBorderGeometrySnapshot(for windowID: WindowID) -> FocusBorderDebugGeometrySnapshot? {
        tiledBorderViews[windowID]?.debugGeometrySnapshot()
    }

    func debugTiledBorderIsVisuallyVisible(for windowID: WindowID) -> Bool {
        guard let window = tiledBorderWindows[windowID] else { return false }
        return window.isVisible && window.alphaValue > 0
    }

    func debugTiledBorderLevelRawValue(for windowID: WindowID) -> Int? {
        tiledBorderWindows[windowID]?.level.rawValue
    }
#endif

    func stop() {
        render(.empty)
        hideCommandOverlay()
        hideHUD()
        hideDragPreview()
    }

    func toggleCommandOverlay(bindings: [HotkeyBinding], dragModifier: ModifierSet, zones: [Zone]) {
        if commandWindow?.isVisible == true {
            hideCommandOverlay()
        } else {
            showCommandOverlay(bindings: bindings, dragModifier: dragModifier, zones: zones)
        }
    }

    var isCommandOverlayVisible: Bool {
        commandWindow?.isVisible == true
    }

    func scrollCommandOverlay(_ direction: CommandOverlayScrollDirection) {
        (commandWindow?.contentView as? CommandOverlayView)?.scroll(direction)
    }

    func showHUD(_ message: String, tone: OverlayTone) {
        guard hudConfig.enabled, !message.isEmpty else { return }

        let screen = commandOverlayScreen()
        let frame = hudFrame(on: screen, message: message)
        let window = hudWindow ?? makeHUDWindow(frame: frame)
        window.contentView = HUDView(message: message, tone: tone)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        hudWindow = window

        hudHideTask?.cancel()
        let durationMillis = HUDConfig.clampedDurationMillis(hudConfig.durationMillis)
        let duration = UInt64(durationMillis) * 1_000_000
        hudHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.hideHUD()
            }
        }
    }

    func showDragPreview(frame: CGRect, title: String, valid: Bool) {
        let appKitFrame = appKitFrame(forAXFrame: frame)
        let window = dragPreviewWindow ?? makeDragPreviewWindow(frame: appKitFrame)
        let view = dragPreviewView ?? DragPreviewView()
        if dragPreviewView == nil {
            window.contentView = view
            dragPreviewView = view
        }
        view.update(title: title, valid: valid)
        window.setFrame(appKitFrame, display: true)
        window.orderFrontRegardless()
        dragPreviewWindow = window
    }

    func hideDragPreview() {
        dragPreviewWindow?.orderOut(nil)
    }

    private func showFocusBorder(_ target: FocusBorderTarget) {
        guard borderConfig.width > 0 else {
            hideFocusBorder()
            return
        }
        guard !shouldSuppressFocusBorder(windowID: target.windowID, frame: target.frame) else {
            hideFocusBorder()
            return
        }

        let appKitFrame = appKitFrame(forAXFrame: target.frame).insetBy(dx: -borderConfig.width / 2, dy: -borderConfig.width / 2)
        let window = borderWindow ?? makeBorderWindow(frame: appKitFrame)
        let view = borderView ?? BorderView(border: borderConfig, cornerRadius: target.cornerRadius)
        if borderView == nil {
            window.contentView = view
            borderView = view
        }
        view.update(border: borderConfig, cornerRadius: target.cornerRadius)
        window.setFrame(appKitFrame, display: true)
        window.alphaValue = 1
        borderWindow = window
        visibleWindowID = target.windowID
        orderFocusBorderWindow(window, above: target.windowID)
        orderUnfocusedTiledBordersBelowFocusedWindow(target)
        scheduleFocusBorderRestacks(above: target.windowID)
    }

    private func showTiledBorder(_ target: FocusBorderTarget, liveWindows: [WindowStackEntry]?) -> Bool {
        let config = Self.tiledBorderConfig
        guard config.width > 0 else {
            hideTiledBorder(target.windowID)
            return false
        }

        if let liveWindows {
            switch tiledBorderTargetVisibility(target: target, liveWindows: liveWindows) {
            case .show:
                break
            case .hideTargetMissing, .hideFrameMismatch:
                hideTiledBorder(target.windowID)
                return true
            }
        }

        let appKitFrame = appKitFrame(forAXFrame: target.frame).insetBy(dx: -config.width / 2, dy: -config.width / 2)
        let window = tiledBorderWindows[target.windowID] ?? makeTiledBorderWindow(frame: appKitFrame)
        let view = tiledBorderViews[target.windowID] ?? BorderView(border: config, cornerRadius: target.cornerRadius)
        if tiledBorderViews[target.windowID] == nil {
            window.contentView = view
            tiledBorderViews[target.windowID] = view
        }
        view.update(border: config, cornerRadius: target.cornerRadius)
        window.setFrame(appKitFrame, display: true)
        orderTiledBorderWindow(window, above: target.windowID)
        tiledBorderWindows[target.windowID] = window
        return false
    }

    private func hideTiledBorder(_ windowID: WindowID) {
        tiledBorderWindows[windowID]?.orderOut(nil)
        tiledBorderWindows.removeValue(forKey: windowID)
        tiledBorderViews.removeValue(forKey: windowID)
    }

    private func hideFocusBorder() {
        cancelFocusBorderRestacks()
        borderWindow?.orderOut(nil)
        visibleWindowID = nil
    }

    private func currentOverlayWindowEntries() -> [OverlayWindowEntry]? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        return windows.compactMap { window in
            guard let cgID = window[kCGWindowNumber as String] as? CGWindowID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == NSWindow.Level.normal.rawValue,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return OverlayWindowEntry(
                cgID: cgID,
                frame: frame
            )
        }
    }

    private func showCommandOverlay(bindings: [HotkeyBinding], dragModifier: ModifierSet, zones: [Zone]) {
        let sections = commandOverlaySections(for: bindings, dragModifier: dragModifier, zones: zones)
        let visibleFrame = commandOverlayVisibleFrame(on: commandOverlayScreen())
        let availableSize = CommandOverlayLayout.availableOverlaySize(in: visibleFrame)
        let metrics = CommandOverlayMetrics.fitting(sections: sections, availableSize: availableSize)
        let frame = CommandOverlayLayout.overlayFrame(in: visibleFrame, contentSize: metrics.contentSize)
        let window = commandWindow ?? makeCommandWindow(frame: frame)
        let overlayView = CommandOverlayView(
            columns: metrics.columns,
            keyColumnWidth: metrics.keyColumnWidth,
            commandColumnWidth: metrics.commandColumnWidth,
            rowsHeight: metrics.rowsHeight
        )
        window.contentView = overlayView
        window.setFrame(frame, display: false)
        overlayView.prepareForFirstDisplay()
        window.orderFrontRegardless()
        commandWindow = window
    }

    func hideCommandOverlay() {
        commandWindow?.orderOut(nil)
    }

    private func hideHUD() {
        hudHideTask?.cancel()
        hudHideTask = nil
        hudWindow?.orderOut(nil)
    }

    private func makeBorderWindow(frame: CGRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        return window
    }

    private func orderFocusBorderWindow(_ window: NSWindow, above targetWindowID: WindowID) {
        if let tiledBorderWindow = tiledBorderWindows[targetWindowID] {
            orderTiledBorderWindow(tiledBorderWindow, above: targetWindowID)
            window.level = tiledBorderWindow.level
        } else {
            window.level = windowLevelMatchingTarget(targetWindowID)
        }
        window.orderFrontRegardless()
    }

    private func scheduleFocusBorderRestacks(above targetWindowID: WindowID) {
        cancelFocusBorderRestacks()
        focusBorderRestackTimers = [0.05, 0.15, 0.30].map { delay in
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restackFocusBorderIfCurrent(above: targetWindowID)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
    }

    private func cancelFocusBorderRestacks() {
        focusBorderRestackTimers.forEach { $0.invalidate() }
        focusBorderRestackTimers.removeAll()
    }

    private func restackFocusBorderIfCurrent(above targetWindowID: WindowID) {
        guard visibleWindowID == targetWindowID,
              let borderWindow,
              borderWindow.isVisible
        else { return }
        orderFocusBorderWindow(borderWindow, above: targetWindowID)
    }

    private func makeTiledBorderWindow(frame: CGRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        return window
    }

    private func orderTiledBorderWindow(_ window: NSWindow, above targetWindowID: WindowID) {
        window.level = windowLevelMatchingTarget(targetWindowID)
        // Materialize the window (`order(.above, relativeTo:)` assigns a windowNumber
        // even when relativeTo is a foreign window — AppKit falls back to "front of
        // level group" in that case).
        window.order(.above, relativeTo: Int(targetWindowID.raw))
        // Best-effort: ask the WindowServer to position the border above its target
        // tile and below any overlapping floating window above the tile. On macOS
        // 15+ for ad-hoc-signed apps these calls return success but no-op; see the
        // top-of-file note. Borders may still appear over unfocused floating
        // windows in that case.
        let connectionID = cgsMainConnectionID?() ?? 0
        if window.windowNumber > 0, connectionID != 0, let orderWindow = cgsOrderWindow {
            _ = orderWindow(
                connectionID,
                UInt32(window.windowNumber),
                kCGSOrderAbove,
                targetWindowID.raw
            )
            pinTiledBorderBelowOverlappingForeignWindows(
                window,
                targetWindowID: targetWindowID,
                connectionID: connectionID,
                orderWindow: orderWindow
            )
        }
    }

    /// Pins the given border window below the lowest foreign window that is
    /// above `targetWindowID` in CG front-to-back order and overlaps the border
    /// frame. No-op if no such window exists.
    private func pinTiledBorderBelowOverlappingForeignWindows(
        _ borderWindow: NSWindow,
        targetWindowID: WindowID,
        connectionID: Int32,
        orderWindow: CGSOrderWindowFunc
    ) {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let ourPID = getpid()
        let borderFrame = borderWindow.frame
        var lowestAboveTarget: CGWindowID?

        for entry in windows {
            guard let cgID = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            // CG list is front-to-back; stop once we hit (or pass) the target tile.
            if cgID == targetWindowID.raw { break }
            // Skip our own windows (border + focus border + HUD).
            if let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == ourPID { continue }
            // Only consider standard windows in the normal level group.
            if let layer = entry[kCGWindowLayer as String] as? Int, layer != NSWindow.Level.normal.rawValue { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgFrame = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            let appKitOverlapFrame = appKitFrame(forAXFrame: cgFrame)
            if appKitOverlapFrame.intersects(borderFrame) {
                lowestAboveTarget = cgID
            }
        }

        guard let pinBelow = lowestAboveTarget else { return }
        _ = orderWindow(
            connectionID,
            UInt32(borderWindow.windowNumber),
            kCGSOrderBelow,
            pinBelow
        )
    }

    private func orderUnfocusedTiledBordersBelowFocusedWindow(_ target: FocusBorderTarget) {
        let focusedFrame = appKitFrame(forAXFrame: target.frame)
        let connectionID = cgsMainConnectionID?() ?? 0
        for (windowID, tiledWindow) in tiledBorderWindows where windowID != target.windowID {
            guard tiledWindow.frame.intersects(focusedFrame) else { continue }
            // Best-effort cross-process reorder; see top-of-file note re: macOS 15+.
            tiledWindow.order(.below, relativeTo: Int(target.windowID.raw))
            if tiledWindow.windowNumber > 0, connectionID != 0, let orderWindow = cgsOrderWindow {
                _ = orderWindow(
                    connectionID,
                    UInt32(tiledWindow.windowNumber),
                    kCGSOrderBelow,
                    target.windowID.raw
                )
            }
        }
    }

    private func windowLevelMatchingTarget(_ targetWindowID: WindowID) -> NSWindow.Level {
        guard let layer = windowLayer(targetWindowID), layer >= NSWindow.Level.normal.rawValue else {
            return .normal
        }
        return NSWindow.Level(rawValue: layer)
    }

    private func windowLayer(_ windowID: WindowID) -> Int? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID.raw
        ) as? [[String: Any]] else {
            return nil
        }
        return windows.first?[kCGWindowLayer as String] as? Int
    }

    private func makeCommandWindow(frame: CGRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return window
    }

    private func makeHUDWindow(frame: CGRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return window
    }

    private func makeDragPreviewWindow(frame: CGRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return window
    }

    private func commandOverlayScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func commandOverlayVisibleFrame(on screen: NSScreen?) -> CGRect {
        screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 700)
    }

    private func hudFrame(on screen: NSScreen?, message: String) -> CGRect {
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 700)
        let availableWidth = max(220, visibleFrame.width - CommandOverlayLayout.screenMargin * 2)
        let textWidth = CommandOverlayLayout.measure(message, font: HUDView.font).width
        let width = min(max(220, ceil(textWidth) + HUDView.horizontalPadding * 2), min(520, availableWidth))
        let height = HUDView.height
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.maxY - CommandOverlayLayout.screenMargin - height,
            width: width,
            height: height
        )
    }

    private func appKitFrame(forAXFrame frame: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.max(by: { lhs, rhs in
            cgFrame(for: lhs).intersection(frame).narwhalArea
                < cgFrame(for: rhs).intersection(frame).narwhalArea
        }) else {
            return frame
        }
        let displayFrame = cgFrame(for: screen)
        return CGRect(
            x: screen.frame.minX + (frame.minX - displayFrame.minX),
            y: screen.frame.minY + (displayFrame.maxY - frame.maxY),
            width: frame.width,
            height: frame.height
        )
    }

    private func cgFrame(for screen: NSScreen) -> CGRect {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.frame
        }
        return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
    }

    private func isScreenFillingAXFrame(_ frame: CGRect) -> Bool {
        let tolerance: CGFloat = 3
        guard let screen = NSScreen.screens.max(by: { lhs, rhs in
            cgFrame(for: lhs).intersection(frame).narwhalArea
                < cgFrame(for: rhs).intersection(frame).narwhalArea
        }) else {
            return false
        }
        let displayFrame = cgFrame(for: screen)
        return frame.narwhalApproximatelyEquals(displayFrame, tolerance: tolerance)
            || frame.narwhalApproximatelyEquals(
                axVisibleFrame(for: screen, displayFrame: displayFrame),
                tolerance: tolerance
            )
            || frame.narwhalFills(
                axVisibleFrame(for: screen, displayFrame: displayFrame),
                tolerance: 18,
                minimumAreaRatio: 0.96
            )
    }

    private func axVisibleFrame(for screen: NSScreen, displayFrame: CGRect) -> CGRect {
        let appFrame = screen.frame
        let appVisible = screen.visibleFrame
        return CGRect(
            x: displayFrame.minX + (appVisible.minX - appFrame.minX),
            y: displayFrame.minY + (appFrame.maxY - appVisible.maxY),
            width: appVisible.width,
            height: appVisible.height
        )
    }

    private func shouldSuppressFocusBorder(windowID: WindowID, frame: CGRect) -> Bool {
        if isScreenFillingAXFrame(frame) {
            focusBorderSuppression = FocusBorderSuppression(windowID: windowID, frame: frame)
            return true
        }
        guard let suppression = focusBorderSuppression, suppression.windowID == windowID else {
            return false
        }
        if frame.narwhalApproximatelyEquals(suppression.frame, tolerance: 18)
            || frame.narwhalFills(suppression.frame, tolerance: 18, minimumAreaRatio: 0.96) {
            return true
        }
        focusBorderSuppression = nil
        return false
    }
}

private struct FocusBorderSuppression {
    let windowID: WindowID
    let frame: CGRect
}

@MainActor
final class CommandOverlayView: NSView {
    private let rowsHeight: CGFloat
    private weak var titleLabel: NSTextField?
    private weak var scrollView: NSScrollView?
    private weak var scrollBarView: CommandOverlayScrollBarView?
    private weak var rowsDocumentView: NSView?
    private weak var rowsContentView: NSView?
    private weak var scrollHintLabel: NSTextField?

    init(
        columns: [[CommandOverlaySection]],
        keyColumnWidth: CGFloat,
        commandColumnWidth: CGFloat,
        rowsHeight: CGFloat
    ) {
        self.rowsHeight = rowsHeight
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(CommandOverlayLayout.titleText)
        build(columns: columns, keyColumnWidth: keyColumnWidth, commandColumnWidth: commandColumnWidth)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        updateDocumentGeometry()
        updateScrollState()
    }

    func prepareForFirstDisplay() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        updateDocumentGeometry()
        updateScrollState()
    }

    func scroll(_ direction: CommandOverlayScrollDirection) {
        guard let scrollView, let rowsDocumentView else { return }
        let clipView = scrollView.contentView
        let viewportHeight = max(clipView.bounds.height, scrollView.bounds.height)
        let documentHeight = max(rowsHeight, rowsDocumentView.bounds.height, viewportHeight)
        let maxY = max(0, documentHeight - viewportHeight)
        let step = max(90, clipView.bounds.height * 0.55)
        let delta = direction == .down ? step : -step
        let nextY = min(max(0, clipView.bounds.origin.y + delta), maxY)
        clipView.scroll(to: CGPoint(x: 0, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
        updateScrollState()
    }

#if NARWHAL_ENABLE_VERIFIERS
    func debugLayoutSnapshot() -> CommandOverlayDebugLayoutSnapshot? {
        layoutSubtreeIfNeeded()
        guard
            let titleLabel,
            let scrollView,
            let scrollBarView,
            let rowsDocumentView,
            let columnsView = rowsContentView as? CommandColumnsView
        else {
            return nil
        }
        rowsDocumentView.layoutSubtreeIfNeeded()
        columnsView.layoutSubtreeIfNeeded()
        return CommandOverlayDebugLayoutSnapshot(
            titleText: titleLabel.stringValue,
            titleFrame: convert(titleLabel.bounds, from: titleLabel),
            scrollViewFrame: convert(scrollView.bounds, from: scrollView),
            scrollBarFrame: convert(scrollBarView.bounds, from: scrollBarView),
            scrollBarHidden: scrollBarView.isHidden,
            scrollBarScrollable: scrollBarView.isScrollableForDebug,
            viewportBounds: scrollView.contentView.bounds,
            documentBounds: rowsDocumentView.bounds,
            columnsBounds: columnsView.bounds,
            columnFrames: columnsView.debugColumnFrames(in: columnsView.bounds),
            separatorFrame: columnsView.debugSeparatorFrame(in: columnsView.bounds),
            rowSnapshots: columnsView.debugRowSnapshots()
        )
    }
#endif

    private func build(columns: [[CommandOverlaySection]], keyColumnWidth: CGFloat, commandColumnWidth: CGFloat) {
        let title = NSTextField(labelWithString: CommandOverlayLayout.titleText)
        title.font = CommandOverlayLayout.titleFont
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        titleLabel = title

        let subtitle = NSTextField(labelWithString: "Active shortcuts grouped by workflow. Scroll with control-option-J/K when needed.")
        subtitle.font = CommandOverlayLayout.subtitleFont
        subtitle.textColor = NSColor.white.withAlphaComponent(0.72)

        let columnsView = CommandColumnsView(
            columns: columns,
            keyColumnWidth: keyColumnWidth,
            commandColumnWidth: commandColumnWidth
        )

        let documentView = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 1, height: rowsHeight))
        documentView.addSubview(columnsView)
        self.rowsContentView = columnsView

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.documentView = documentView
        self.scrollView = scrollView
        self.rowsDocumentView = documentView

        let scrollBarView = CommandOverlayScrollBarView()
        scrollBarView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollBarView = scrollBarView

        let rowsFrame = NSStackView(views: [scrollView, scrollBarView])
        rowsFrame.translatesAutoresizingMaskIntoConstraints = false
        rowsFrame.orientation = .horizontal
        rowsFrame.alignment = .height
        rowsFrame.spacing = CommandOverlayLayout.scrollBarGap

        let scrollHint = NSTextField(labelWithString: "More commands below - scroll with control-option-J")
        scrollHint.font = CommandOverlayLayout.scrollHintFont
        scrollHint.textColor = NSColor.white.withAlphaComponent(0.72)
        scrollHint.lineBreakMode = .byTruncatingTail
        scrollHint.isHidden = true
        self.scrollHintLabel = scrollHint

        let stack = NSStackView(views: [title, subtitle, rowsFrame, scrollHint])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CommandOverlayLayout.stackSpacing
        addSubview(stack)

        let constraints: [NSLayoutConstraint] = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CommandOverlayLayout.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CommandOverlayLayout.horizontalPadding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: CommandOverlayLayout.topPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CommandOverlayLayout.bottomPadding),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowsFrame.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollBarView.widthAnchor.constraint(equalToConstant: CommandOverlayLayout.scrollBarWidth)
        ]
        NSLayoutConstraint.activate(constraints)
    }

    private func updateDocumentGeometry() {
        guard let scrollView, let rowsDocumentView else { return }
        let viewportHeight = max(scrollView.contentView.bounds.height, scrollView.bounds.height)
        let fallbackWidth = max(0, bounds.width - CommandOverlayLayout.horizontalPadding * 2)
        let viewportWidth = scrollView.contentView.bounds.width > 0
            ? scrollView.contentView.bounds.width
            : max(0, fallbackWidth - CommandOverlayLayout.scrollBarGutterWidth)
        let documentHeight = max(rowsHeight, viewportHeight)
        let documentSize = NSSize(
            width: viewportWidth,
            height: documentHeight
        )
        rowsDocumentView.setFrameSize(documentSize)
        rowsContentView?.frame = CGRect(origin: .zero, size: documentSize)
        rowsContentView?.needsLayout = true
        rowsContentView?.needsDisplay = true
    }

    private func updateScrollState() {
        guard let scrollView, let scrollBarView else { return }
        let clipView = scrollView.contentView
        let viewportHeight = max(clipView.bounds.height, scrollView.bounds.height)
        let documentHeight = max(rowsHeight, viewportHeight)
        let maxY = max(0, documentHeight - viewportHeight)
        let scrollable = maxY > 1
        scrollBarView.update(
            viewportHeight: viewportHeight,
            documentHeight: documentHeight,
            contentOffsetY: clipView.bounds.origin.y
        )
        scrollHintLabel?.isHidden = !scrollable

        guard scrollable else { return }
        let y = clipView.bounds.origin.y
        if y <= 1 {
            scrollHintLabel?.stringValue = "More commands below - scroll with control-option-J"
        } else if y >= maxY - 1 {
            scrollHintLabel?.stringValue = "More commands above - scroll with control-option-K"
        } else {
            scrollHintLabel?.stringValue = "More commands above and below - scroll with control-option-J/K"
        }
    }
}

#if NARWHAL_ENABLE_VERIFIERS
@MainActor
struct CommandOverlayDebugLayoutSnapshot {
    let titleText: String
    let titleFrame: CGRect
    let scrollViewFrame: CGRect
    let scrollBarFrame: CGRect
    let scrollBarHidden: Bool
    let scrollBarScrollable: Bool
    let viewportBounds: CGRect
    let documentBounds: CGRect
    let columnsBounds: CGRect
    let columnFrames: [CGRect]
    let separatorFrame: CGRect?
    let rowSnapshots: [CommandOverlayDebugRowSnapshot]
}

struct CommandOverlayDebugRowSnapshot {
    let key: String
    let command: String
    let detail: String
    let bounds: CGRect
    let keyFrame: CGRect
    let commandFrame: CGRect
    let detailFrame: CGRect
    let accessibilityLabel: String?
}
#endif

@MainActor
private final class CommandOverlayScrollBarView: NSView {
    private var viewportHeight: CGFloat = 0
    private var documentHeight: CGFloat = 0
    private var contentOffsetY: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    var isScrollableForDebug: Bool {
        viewportHeight > 1 && documentHeight > viewportHeight + 1
    }

    func update(viewportHeight: CGFloat, documentHeight: CGFloat, contentOffsetY: CGFloat) {
        self.viewportHeight = viewportHeight
        self.documentHeight = documentHeight
        self.contentOffsetY = contentOffsetY
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard viewportHeight > 1, documentHeight > viewportHeight + 1 else { return }

        let track = CGRect(
            x: floor((bounds.width - CommandOverlayLayout.scrollBarTrackWidth) / 2),
            y: 0,
            width: CommandOverlayLayout.scrollBarTrackWidth,
            height: bounds.height
        )
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.width / 2, yRadius: track.width / 2).fill()

        let thumbHeight = max(
            CommandOverlayLayout.scrollBarMinimumThumbHeight,
            bounds.height * min(1, viewportHeight / documentHeight)
        )
        let maxOffset = max(1, documentHeight - viewportHeight)
        let maxThumbY = max(0, bounds.height - thumbHeight)
        let thumbY = maxThumbY * min(1, max(0, contentOffsetY / maxOffset))
        let thumb = CGRect(
            x: track.minX,
            y: thumbY,
            width: track.width,
            height: thumbHeight
        )
        NSColor.white.withAlphaComponent(0.46).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: thumb.width / 2, yRadius: thumb.width / 2).fill()
    }
}

@MainActor
private final class CommandSectionView: NSView {
    private let rowViews: [CommandRowView]

    init(section: CommandOverlaySection, keyColumnWidth: CGFloat, commandColumnWidth: CGFloat) {
        rowViews = section.rows.map { row in
            CommandRowView(
                key: row.key,
                command: row.command,
                detail: row.detail,
                keyColumnWidth: keyColumnWidth,
                commandColumnWidth: commandColumnWidth
            )
        }
        super.init(frame: .zero)

        let header = NSTextField(labelWithString: section.title)
        header.font = CommandOverlayLayout.sectionFont
        header.textColor = NSColor.white.withAlphaComponent(0.92)
        header.setContentCompressionResistancePriority(.required, for: .horizontal)

        let purpose = NSTextField(labelWithString: section.purpose)
        purpose.font = CommandOverlayLayout.sectionPurposeFont
        purpose.textColor = NSColor.white.withAlphaComponent(0.62)
        purpose.lineBreakMode = .byTruncatingTail

        let headerStack = NSStackView(views: [header, purpose])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2

        let rowStack = NSStackView(views: rowViews)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = CommandOverlayLayout.rowSpacing

        let stack = NSStackView(views: [headerStack, rowStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CommandOverlayLayout.sectionHeaderSpacing
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(lessThanOrEqualTo: headerStack.widthAnchor),
            purpose.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.widthAnchor.constraint(equalTo: widthAnchor),
            rowStack.widthAnchor.constraint(equalTo: widthAnchor),
            heightAnchor.constraint(equalToConstant: CommandOverlayLayout.sectionHeight(rowCount: section.rows.count))
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

#if NARWHAL_ENABLE_VERIFIERS
    func debugRowSnapshots() -> [CommandOverlayDebugRowSnapshot] {
        rowViews.map { $0.debugSnapshot() }
    }
#endif
}

@MainActor
private final class CommandRowView: NSView {
    private let keyLabel: NSTextField
    private let commandLabel: NSTextField
    private let detailLabel: NSTextField

    init(key: String, command: String, detail: String, keyColumnWidth: CGFloat, commandColumnWidth: CGFloat) {
        keyLabel = NSTextField(labelWithString: key)
        commandLabel = NSTextField(labelWithString: command)
        detailLabel = NSTextField(labelWithString: detail)
        super.init(frame: .zero)

        keyLabel.font = CommandOverlayLayout.keyFont
        keyLabel.textColor = .white
        keyLabel.alignment = .left
        keyLabel.lineBreakMode = .byTruncatingMiddle
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        commandLabel.font = CommandOverlayLayout.commandFont
        commandLabel.textColor = NSColor.white.withAlphaComponent(0.90)
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        detailLabel.font = CommandOverlayLayout.detailFont
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.68)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyLabel.setAccessibilityElement(false)
        commandLabel.setAccessibilityElement(false)
        detailLabel.setAccessibilityElement(false)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(spokenAccessibilityText("\(key): \(command). \(detail)"))

        let meaningStack = NSStackView(views: [commandLabel, detailLabel])
        meaningStack.translatesAutoresizingMaskIntoConstraints = false
        meaningStack.orientation = .vertical
        meaningStack.alignment = .leading
        meaningStack.spacing = 2

        let stack = NSStackView(views: [keyLabel, meaningStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = CommandOverlayLayout.rowGap
        addSubview(stack)

        NSLayoutConstraint.activate([
            keyLabel.widthAnchor.constraint(equalToConstant: keyColumnWidth),
            meaningStack.widthAnchor.constraint(equalToConstant: commandColumnWidth),
            commandLabel.widthAnchor.constraint(equalTo: meaningStack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: meaningStack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: CommandOverlayLayout.rowHeight)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

#if NARWHAL_ENABLE_VERIFIERS
    func debugSnapshot() -> CommandOverlayDebugRowSnapshot {
        layoutSubtreeIfNeeded()
        return CommandOverlayDebugRowSnapshot(
            key: keyLabel.stringValue,
            command: commandLabel.stringValue,
            detail: detailLabel.stringValue,
            bounds: bounds,
            keyFrame: convert(keyLabel.bounds, from: keyLabel),
            commandFrame: convert(commandLabel.bounds, from: commandLabel),
            detailFrame: convert(detailLabel.bounds, from: detailLabel),
            accessibilityLabel: accessibilityLabel()
        )
    }
#endif
}

@MainActor
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class CommandColumnsView: NSView {
    private let columns: [[CommandOverlaySection]]
    private let columnViews: [CommandColumnView]
    private let separatorView: NSView

    override var isFlipped: Bool { true }

    init(columns: [[CommandOverlaySection]], keyColumnWidth: CGFloat, commandColumnWidth: CGFloat) {
        self.columns = columns
        columnViews = columns.map {
            CommandColumnView(
                sections: $0,
                keyColumnWidth: keyColumnWidth,
                commandColumnWidth: commandColumnWidth
            )
        }
        separatorView = NSView(frame: .zero)
        super.init(frame: .zero)
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        columnViews.forEach(addSubview)
        addSubview(separatorView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let frames = CommandOverlayLayout.columnFrames(in: bounds, columnCount: columns.count)
        for (index, columnView) in columnViews.enumerated() {
            guard frames.columns.indices.contains(index) else {
                columnView.frame = .zero
                continue
            }
            columnView.frame = frames.columns[index]
        }
        if let separator = frames.separator {
            separatorView.isHidden = false
            separatorView.frame = separator
        } else {
            separatorView.isHidden = true
            separatorView.frame = .zero
        }
    }

#if NARWHAL_ENABLE_VERIFIERS
    func debugColumnFrames(in bounds: CGRect) -> [CGRect] {
        CommandOverlayLayout.columnFrames(in: bounds, columnCount: columns.count).columns
    }

    func debugSeparatorFrame(in bounds: CGRect) -> CGRect? {
        CommandOverlayLayout.columnFrames(in: bounds, columnCount: columns.count).separator
    }

    func debugRowSnapshots() -> [CommandOverlayDebugRowSnapshot] {
        columnViews.flatMap { $0.debugRowSnapshots() }
    }
#endif
}

@MainActor
private final class CommandColumnView: NSView {
    private let sections: [CommandOverlaySection]
    private let sectionViews: [CommandSectionView]

    override var isFlipped: Bool { true }

    init(sections: [CommandOverlaySection], keyColumnWidth: CGFloat, commandColumnWidth: CGFloat) {
        self.sections = sections
        sectionViews = sections.map {
            CommandSectionView(
                section: $0,
                keyColumnWidth: keyColumnWidth,
                commandColumnWidth: commandColumnWidth
            )
        }
        super.init(frame: .zero)
        sectionViews.forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (section, sectionView) in zip(sections, sectionViews) {
            let height = CommandOverlayLayout.sectionHeight(rowCount: section.rows.count)
            sectionView.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + CommandOverlayLayout.sectionSpacing
        }
    }

#if NARWHAL_ENABLE_VERIFIERS
    func debugRowSnapshots() -> [CommandOverlayDebugRowSnapshot] {
        sectionViews.flatMap { $0.debugRowSnapshots() }
    }
#endif
}

struct CommandOverlayMetrics {
    let contentSize: CGSize
    let columns: [[CommandOverlaySection]]
    let keyColumnWidth: CGFloat
    let commandColumnWidth: CGFloat
    let rowsHeight: CGFloat

    init(sections: [CommandOverlaySection]) {
        self.init(sections: sections, columns: CommandOverlayLayout.semanticColumns(sections))
    }

    static func fitting(sections: [CommandOverlaySection], availableSize: CGSize) -> CommandOverlayMetrics {
        let expanded = CommandOverlayMetrics(sections: sections)
        let expandedWidth = CommandOverlayLayout.windowWidth(
            forContentSize: expanded.contentSize,
            availableHeight: availableSize.height
        )
        guard expandedWidth > availableSize.width else {
            return expanded
        }

        let compactRowsWidth = max(
            1,
            availableSize.width
                - CommandOverlayLayout.horizontalPadding * 2
                - CommandOverlayLayout.scrollBarGutterWidth
        )
        return CommandOverlayMetrics(
            sections: sections,
            columns: CommandOverlayLayout.singleColumn(sections),
            maximumRowContentWidth: compactRowsWidth
        )
    }

    private init(
        sections: [CommandOverlaySection],
        columns: [[CommandOverlaySection]],
        maximumRowContentWidth: CGFloat? = nil
    ) {
        self.columns = columns
        let rows = sections.flatMap(\.rows)
        let keyTexts = rows.map(\.key)
        let commandTexts = rows.map(\.command)
        let detailTexts = rows.map(\.detail)
        let measuredKeyWidth = keyTexts.map {
            CommandOverlayLayout.measure($0, font: CommandOverlayLayout.keyFont).width
        }.max() ?? 0
        let measuredCommandWidth = commandTexts.map {
            CommandOverlayLayout.measure($0, font: CommandOverlayLayout.commandFont).width
        }.max() ?? 0
        let measuredDetailWidth = detailTexts.map {
            CommandOverlayLayout.measure($0, font: CommandOverlayLayout.detailFont).width
        }.max() ?? 0
        let measuredSectionWidth = sections.map {
            CommandOverlayLayout.measure($0.title, font: CommandOverlayLayout.sectionFont).width
        }.max() ?? 0
        let measuredPurposeWidth = sections.map {
            CommandOverlayLayout.measure($0.purpose, font: CommandOverlayLayout.sectionPurposeFont).width
        }.max() ?? 0

        let preferredKeyColumnWidth = ceil(min(
            CommandOverlayLayout.maximumKeyColumnWidth,
            max(CommandOverlayLayout.minimumKeyColumnWidth, measuredKeyWidth)
        ))
        let preferredCommandColumnWidth = ceil(min(
            CommandOverlayLayout.maximumCommandColumnWidth,
            max(
                CommandOverlayLayout.minimumCommandColumnWidth,
                measuredCommandWidth + CommandOverlayLayout.textFitPadding,
                measuredDetailWidth + CommandOverlayLayout.textFitPadding
            )
        ))
        let resolvedWidths = CommandOverlayLayout.commandRowColumnWidths(
            preferredKeyWidth: preferredKeyColumnWidth,
            preferredCommandWidth: preferredCommandColumnWidth,
            maximumRowContentWidth: maximumRowContentWidth
        )
        keyColumnWidth = resolvedWidths.key
        commandColumnWidth = resolvedWidths.command
        rowsHeight = columns.map(CommandOverlayLayout.sectionsHeight).max() ?? 0

        let titleWidth = CommandOverlayLayout.measure(
            CommandOverlayLayout.titleText,
            font: CommandOverlayLayout.titleFont
        ).width
        let subtitleWidth = CommandOverlayLayout.measure(
            "Active shortcuts grouped by workflow. Scroll with control-option-J/K when needed.",
            font: CommandOverlayLayout.subtitleFont
        ).width
        let columnCount = max(1, columns.count)
        let headerWidth = max(measuredSectionWidth, measuredPurposeWidth)
        let commandWidth = keyColumnWidth
            + CommandOverlayLayout.rowGap
            + commandColumnWidth
        let columnWidth = max(CommandOverlayLayout.minimumColumnWidth, headerWidth, commandWidth)
        let columnsWidth = columnWidth * CGFloat(columnCount)
            + CommandOverlayLayout.columnsSeparatorWidth(columnCount: columnCount)
        let contentWidth = CommandOverlayLayout.horizontalPadding * 2 + max(
            titleWidth,
            subtitleWidth,
            columnsWidth
        )
        let contentHeight = CommandOverlayLayout.topPadding
            + CommandOverlayLayout.lineHeight(font: CommandOverlayLayout.titleFont)
            + CommandOverlayLayout.stackSpacing
            + CommandOverlayLayout.lineHeight(font: CommandOverlayLayout.subtitleFont)
            + CommandOverlayLayout.stackSpacing
            + rowsHeight
            + CommandOverlayLayout.bottomPadding

        contentSize = CGSize(width: ceil(contentWidth), height: ceil(contentHeight))
    }
}

enum CommandOverlayLayout {
    static let titleText = "Narwhal Commands"
    static let screenMargin: CGFloat = 24
    static let horizontalPadding: CGFloat = 32
    static let topPadding: CGFloat = 28
    static let bottomPadding: CGFloat = 28
    static let stackSpacing: CGFloat = 16
    static let centerGutter: CGFloat = 56
    static let columnSeparatorWidth: CGFloat = 2
    static let scrollBarGap: CGFloat = 14
    static let scrollBarWidth: CGFloat = 14
    static let scrollBarTrackWidth: CGFloat = 5
    static let scrollBarMinimumThumbHeight: CGFloat = 44
    static let scrollBarGutterWidth: CGFloat = scrollBarGap + scrollBarWidth
    static let sectionSpacing: CGFloat = 18
    static let sectionHeaderSpacing: CGFloat = 8
    static let sectionPurposeGap: CGFloat = 10
    static let rowSpacing: CGFloat = 6
    static let rowGap: CGFloat = 14
    static let rowHeight: CGFloat = 42
    static let sectionHeaderHeight: CGFloat = 34
    static let minimumColumnWidth: CGFloat = 430
    static let minimumKeyColumnWidth: CGFloat = 96
    static let maximumKeyColumnWidth: CGFloat = 220
    static let minimumCommandColumnWidth: CGFloat = 260
    static let maximumCommandColumnWidth: CGFloat = 580
    static let minimumCompactKeyColumnWidth: CGFloat = 72
    static let minimumCompactCommandColumnWidth: CGFloat = 120
    static let textFitPadding: CGFloat = 12
    static let titleFont = NSFont.systemFont(ofSize: 24, weight: .semibold)
    static let subtitleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let sectionFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let sectionPurposeFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let keyFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
    static let commandFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let detailFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let scrollHintFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    static func rowsHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * rowHeight + CGFloat(count - 1) * rowSpacing
    }

    static func sectionHeight(rowCount: Int) -> CGFloat {
        sectionHeaderHeight + sectionHeaderSpacing + rowsHeight(count: rowCount)
    }

    static func sectionsHeight(_ sections: [CommandOverlaySection]) -> CGFloat {
        guard !sections.isEmpty else { return 0 }
        let sectionHeights = sections.reduce(CGFloat(0)) { total, section in
            total + sectionHeight(rowCount: section.rows.count)
        }
        return sectionHeights + CGFloat(sections.count - 1) * sectionSpacing
    }

    static func semanticColumns(_ sections: [CommandOverlaySection]) -> [[CommandOverlaySection]] {
        let leftTitles: Set<String> = [
            CommandOverlayCategory.movement.title,
            CommandOverlayCategory.placement.title,
            CommandOverlayCategory.dragging.title
        ]
        let rightTitles: Set<String> = [
            CommandOverlayCategory.arrangement.title,
            CommandOverlayCategory.overlay.title,
            CommandOverlayCategory.system.title
        ]
        let left = sections.filter { leftTitles.contains($0.title) }
        let rightOrder = [
            CommandOverlayCategory.system.title,
            CommandOverlayCategory.arrangement.title,
            CommandOverlayCategory.overlay.title
        ]
        let right = rightOrder.flatMap { title in
            sections.filter { $0.title == title }
        }
        let assignedTitles = leftTitles.union(rightTitles)
        let unassigned = sections.filter { !assignedTitles.contains($0.title) }

        if left.isEmpty, right.isEmpty {
            return sections.isEmpty ? [] : [sections]
        }
        if left.isEmpty {
            return [right + unassigned]
        }
        if right.isEmpty {
            return [left + unassigned]
        }
        return [left, right + unassigned]
    }

    static func singleColumn(_ sections: [CommandOverlaySection]) -> [[CommandOverlaySection]] {
        sections.isEmpty ? [] : [sections]
    }

    static func columnsSeparatorWidth(columnCount: Int) -> CGFloat {
        guard columnCount > 1 else { return 0 }
        return centerGutter * 2 + columnSeparatorWidth
    }

    static func columnFrames(in bounds: CGRect, columnCount: Int) -> (columns: [CGRect], separator: CGRect?) {
        let frames = CommandOverlayGridLayout.columnFrames(
            in: bounds,
            columnCount: columnCount,
            centerGutter: centerGutter,
            separatorWidth: columnSeparatorWidth
        )
        return (frames.columns, frames.separator)
    }

    static func measure(_ text: String, font: NSFont) -> CGSize {
        let attributed = text as NSString
        return attributed.size(withAttributes: [.font: font])
    }

    static func lineHeight(font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func availableOverlaySize(in visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: max(1, visibleFrame.width - screenMargin * 2),
            height: max(1, visibleFrame.height - screenMargin * 2)
        )
    }

    static func windowWidth(forContentSize contentSize: CGSize, availableHeight: CGFloat) -> CGFloat {
        let scrollBarAllowance = contentSize.height > availableHeight ? scrollBarGutterWidth : 0
        return contentSize.width + scrollBarAllowance
    }

    static func windowSize(forContentSize contentSize: CGSize, availableSize: CGSize) -> CGSize {
        CGSize(
            width: min(windowWidth(forContentSize: contentSize, availableHeight: availableSize.height), availableSize.width),
            height: min(contentSize.height, availableSize.height)
        )
    }

    static func overlayFrame(in visibleFrame: CGRect, contentSize: CGSize) -> CGRect {
        let availableSize = availableOverlaySize(in: visibleFrame)
        let windowSize = windowSize(forContentSize: contentSize, availableSize: availableSize)
        return CGRect(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    static func commandRowColumnWidths(
        preferredKeyWidth: CGFloat,
        preferredCommandWidth: CGFloat,
        maximumRowContentWidth: CGFloat?
    ) -> (key: CGFloat, command: CGFloat) {
        guard let maximumRowContentWidth else {
            return (preferredKeyWidth, preferredCommandWidth)
        }

        let rowBudget = max(1, maximumRowContentWidth - rowGap)
        var keyWidth = min(
            preferredKeyWidth,
            max(minimumCompactKeyColumnWidth, floor(rowBudget * 0.34))
        )
        var commandWidth = min(preferredCommandWidth, max(1, rowBudget - keyWidth))
        if commandWidth < minimumCompactCommandColumnWidth {
            keyWidth = min(keyWidth, max(1, rowBudget - minimumCompactCommandColumnWidth))
            commandWidth = max(1, rowBudget - keyWidth)
        }
        return (ceil(keyWidth), ceil(commandWidth))
    }
}


func commandOverlayKeyDescription(_ key: KeySpec) -> String {
    let modifiers = [
        key.modifiers.contains(.control) ? "⌃" : nil,
        key.modifiers.contains(.option) ? "⌥" : nil,
        key.modifiers.contains(.shift) ? "⇧" : nil,
        key.modifiers.contains(.command) ? "⌘" : nil
    ].compactMap { $0 }
    return modifiers.joined() + key.key.uppercased()
}

private func describe(_ modifiers: ModifierSet) -> String {
    let values = [
        modifiers.contains(.control) ? "⌃" : nil,
        modifiers.contains(.option) ? "⌥" : nil,
        modifiers.contains(.shift) ? "⇧" : nil,
        modifiers.contains(.command) ? "⌘" : nil
    ].compactMap { $0 }
    return values.isEmpty ? "" : values.joined()
}

func spokenAccessibilityText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "⌃", with: "control ")
        .replacingOccurrences(of: "⌥", with: "option ")
        .replacingOccurrences(of: "⇧", with: "shift ")
        .replacingOccurrences(of: "⌘", with: "command ")
        .replacingOccurrences(of: "  ", with: " ")
}

private func describe(_ action: HotkeyAction) -> String {
    commandOverlayDescription(for: action)
}

private func describe(_ template: CommandTemplate) -> String {
    commandOverlayDescription(for: .command(template))
}

struct CommandOverlaySection {
    let title: String
    let purpose: String
    let rows: [CommandOverlayRow]
}

struct CommandOverlayRow {
    let key: String
    let command: String
    let detail: String
}

enum CommandOverlayCategory: CaseIterable {
    case movement
    case placement
    case dragging
    case arrangement
    case overlay
    case system

    var title: String {
        switch self {
        case .movement:
            return "Movement"
        case .placement:
            return "Placing Windows"
        case .dragging:
            return "Dragging Windows"
        case .arrangement:
            return "Changing Layout"
        case .overlay:
            return "Overlay"
        case .system:
            return "System"
        }
    }

    var purpose: String {
        switch self {
        case .movement:
            return "Move focus without changing window positions."
        case .placement:
            return "Put the focused window into a lane, center, or floating state."
        case .dragging:
            return "Drop the focused window into a configured tile zone."
        case .arrangement:
            return "Reorder or resize the current tiled layout."
        case .overlay:
            return "Navigate this command list while it is open."
        case .system:
            return "Reload, inspect, or reset Narwhal state."
        }
    }
}

func commandOverlaySections(
    for bindings: [HotkeyBinding],
    dragModifier: ModifierSet,
    zones: [Zone]
) -> [CommandOverlaySection] {
    var rowsByCategory: [CommandOverlayCategory: [CommandOverlayRow]] = [:]
    for binding in bindings {
        let category = commandOverlayCategory(for: binding.action)
        rowsByCategory[category, default: []].append(CommandOverlayRow(
            key: commandOverlayKeyDescription(binding.key),
            command: commandOverlayCommand(for: binding.action),
            detail: commandOverlayDescription(for: binding.action)
        ))
    }

    let sections = CommandOverlayCategory.allCases.compactMap { category -> CommandOverlaySection? in
        if category == .dragging {
            return commandOverlayDragSection(modifier: dragModifier, zones: zones)
        }
        if category == .overlay {
            return commandOverlayControlSection()
        }
        guard let rows = rowsByCategory[category], !rows.isEmpty else { return nil }
        return CommandOverlaySection(title: category.title, purpose: category.purpose, rows: rows)
    }
    if !sections.isEmpty {
        return sections
    }
    return [
        CommandOverlaySection(
            title: "System",
            purpose: "Reload, inspect, or reset Narwhal state.",
            rows: [
                CommandOverlayRow(
                    key: "",
                    command: "No shortcuts",
                    detail: "No active command shortcuts in the current config"
                )
            ]
        )
    ]
}

private func commandOverlayDragSection(modifier: ModifierSet, zones: [Zone]) -> CommandOverlaySection? {
    guard !zones.isEmpty else { return nil }
    let gesture = modifier.isEmpty ? "drag" : "\(describe(modifier)) drag"
    let startDetail = modifier.isEmpty
        ? "Drag a focused window title bar, then release on a highlighted zone"
        : "Hold \(describe(modifier)) before mouse-down, drag the focused window, then release on a highlighted zone"
    let zoneRows = zones.map { zone in
        CommandOverlayRow(
            key: zone.id.raw,
            command: commandOverlayZoneCommand(for: zone.action),
            detail: commandOverlayZoneDescription(for: zone.action)
        )
    }
    return CommandOverlaySection(
        title: CommandOverlayCategory.dragging.title,
        purpose: CommandOverlayCategory.dragging.purpose,
        rows: [
            CommandOverlayRow(key: gesture, command: "Drag to tile", detail: startDetail)
        ] + zoneRows
    )
}

private func commandOverlayControlSection() -> CommandOverlaySection {
    CommandOverlaySection(
        title: CommandOverlayCategory.overlay.title,
        purpose: CommandOverlayCategory.overlay.purpose,
        rows: [
            CommandOverlayRow(
                key: "⌃⌥J",
                command: "Scroll down",
                detail: "Scroll this overlay down without moving window focus"
            ),
            CommandOverlayRow(
                key: "⌃⌥K",
                command: "Scroll up",
                detail: "Scroll this overlay up without moving window focus"
            )
        ]
    )
}

private func commandOverlayCategory(for action: HotkeyAction) -> CommandOverlayCategory {
    switch action {
    case .command(let template):
        switch template {
        case .focusDirection, .focusCycle, .focusPrevious:
            return .movement
        case .push, .center, .eject, .toggleFloat, .moveToNextDisplay, .maximizeReset:
            return .placement
        case .swap, .resizeSplit, .balance, .shuffle, .cascade, .undoLayout, .redoLayout:
            return .arrangement
        case .togglePause, .resetLayout:
            return .system
        }
    case .openFinderWindow, .reloadConfig, .showCommands:
        return .system
    }
}

func commandOverlayDescription(for action: HotkeyAction) -> String {
    switch action {
    case .command(let template):
        return commandOverlayDescription(for: template)
    case .openFinderWindow:
        return "Open a Finder window rooted at the current user's home folder"
    case .reloadConfig:
        return "Reload config and rebind shortcuts"
    case .showCommands:
        return "Show or hide this command overlay"
    }
}

func commandOverlayCommand(for action: HotkeyAction) -> String {
    switch action {
    case .command(let template):
        return commandOverlayCommand(for: template)
    case .openFinderWindow:
        return "Open Finder"
    case .reloadConfig:
        return "Reload config"
    case .showCommands:
        return "Show commands"
    }
}

private func commandOverlayCommand(for template: CommandTemplate) -> String {
    switch template {
    case .push(let direction):
        return "Place \(shortDirectionName(direction))"
    case .center:
        return "Place center"
    case .eject:
        return "Pop out"
    case .swap(let direction):
        return "Swap \(shortDirectionName(direction))"
    case .resizeSplit(let direction, _):
        return "Resize \(shortDirectionName(direction))"
    case .focusDirection(let direction):
        return "Focus \(shortDirectionName(direction))"
    case .focusCycle(let direction):
        return "Focus floating \(direction.rawValue)"
    case .focusPrevious:
        return "Focus previous"
    case .toggleFloat:
        return "Toggle float"
    case .balance:
        return "Balance splits"
    case .shuffle:
        return "Shuffle reset"
    case .cascade:
        return "Cascade reset"
    case .maximizeReset:
        return "Max reset"
    case .undoLayout:
        return "Undo layout"
    case .redoLayout:
        return "Redo layout"
    case .moveToNextDisplay:
        return "Move display"
    case .togglePause:
        return "Pause tiling"
    case .resetLayout:
        return "Reset layout"
    }
}

private func commandOverlayZoneCommand(for action: ZoneAction) -> String {
    switch action {
    case .insertAsHalf(let direction):
        return "Drop \(shortDirectionName(direction))"
    case .insertAsQuarter(let corner):
        return "Drop \(cornerName(corner))"
    case .insertAsCenter:
        return "Drop center"
    case .insertAtSubtree:
        return "Drop subtree"
    }
}

private func commandOverlayZoneDescription(for action: ZoneAction) -> String {
    switch action {
    case .insertAsHalf(let direction):
        return "Release in this zone to retile into the \(edgeName(direction)) lane"
    case .insertAsQuarter(let corner):
        return "Release in this zone to retile into the \(cornerName(corner)) quarter"
    case .insertAsCenter:
        return "Release in this zone to retile into the center lane"
    case .insertAtSubtree(let path):
        return "Release in this zone to retile inside subtree \(path)"
    }
}

private func commandOverlayDescription(for template: CommandTemplate) -> String {
    switch template {
    case .push(let direction):
        return "Tile focused window into the \(edgeName(direction)) lane"
    case .center:
        return "Tile focused window into the center lane"
    case .eject:
        return "Pop focused tiled window out of the layout and leave it floating"
    case .swap(let direction):
        return "Swap focused tiled window with the nearest tiled neighbor \(neighborName(direction))"
    case .resizeSplit(let direction, let delta):
        return resizeDescription(direction: direction, delta: delta)
    case .focusDirection(let direction):
        return "Move focus to the nearest tiled window \(neighborName(direction))"
    case .focusCycle(let direction):
        return "Focus the \(direction.rawValue) non-tiled window in screen order"
    case .focusPrevious:
        return "Return focus to the last focused window"
    case .toggleFloat:
        return "If tiled, float focused window; if floating, tile it in the center"
    case .balance:
        return "Reset active Space split weights to equal sizes"
    case .shuffle:
        return "Clear tile memory and place resizable windows as random quarter-screen frames"
    case .cascade:
        return "Clear tile memory and stack resizable windows as offset quarter-screen frames"
    case .maximizeReset:
        return "Maximize focused window and clear the rest of tile memory"
    case .undoLayout:
        return "Restore the previous tiled layout"
    case .redoLayout:
        return "Reapply the next tiled layout after an undo"
    case .moveToNextDisplay:
        return "Move focused window to the next display and tile it in the center"
    case .togglePause:
        return "Pause or resume automatic tiling actions"
    case .resetLayout:
        return "Clear tiling state, floating order, focus memory, and constraints"
    }
}

private func cornerName(_ corner: Corner) -> String {
    switch corner {
    case .topLeft:
        return "top-left"
    case .topRight:
        return "top-right"
    case .bottomLeft:
        return "bottom-left"
    case .bottomRight:
        return "bottom-right"
    }
}

private func shortDirectionName(_ direction: Direction) -> String {
    switch direction {
    case .left:
        return "left"
    case .right:
        return "right"
    case .up:
        return "up"
    case .down:
        return "down"
    }
}

private func edgeName(_ direction: Direction) -> String {
    switch direction {
    case .left:
        return "left edge"
    case .right:
        return "right edge"
    case .up:
        return "top edge"
    case .down:
        return "bottom edge"
    }
}

private func neighborName(_ direction: Direction) -> String {
    switch direction {
    case .left:
        return "to the left"
    case .right:
        return "to the right"
    case .up:
        return "above"
    case .down:
        return "below"
    }
}

private func resizeDescription(direction: Direction, delta: Double) -> String {
    let amount = formatDelta(abs(delta))
    if delta < 0 {
        return "Shrink focused tile away from the \(resizeNeighborName(direction)) by \(amount)"
    }
    return "Grow focused tile toward the \(resizeNeighborName(direction)) by \(amount)"
}

private func resizeNeighborName(_ direction: Direction) -> String {
    switch direction {
    case .left:
        return "left neighbor"
    case .right:
        return "right neighbor"
    case .up:
        return "upper neighbor"
    case .down:
        return "lower neighbor"
    }
}

private func formatDelta(_ delta: Double) -> String {
    if delta.rounded() == delta {
        return String(format: "%.0f", delta)
    }
    return String(format: "%.2f", delta)
        .trimmingCharacters(in: CharacterSet(charactersIn: "0"))
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
}
