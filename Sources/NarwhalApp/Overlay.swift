import AppKit
import QuartzCore
import NarwhalAppSupport
import NarwhalCore

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

    func updateFocusBorder(_ effect: FocusBorderEffect) {
        switch effect {
        case .show(let target):
            showFocusBorder(target)
        case .hide:
            hideFocusBorder()
        }
    }

    func suppressFocusBorder(for windowID: WindowID, frame: CGRect) {
        focusBorderSuppression = FocusBorderSuppression(windowID: windowID, frame: frame)
        hideFocusBorder()
    }

    func updateTiledBorders(_ targets: [FocusBorderTarget]) {
        let nextIDs = Set(targets.map(\.windowID))
        for windowID in tiledBorderWindows.keys where !nextIDs.contains(windowID) {
            hideTiledBorder(windowID)
        }

        for target in targets.sorted(by: { $0.windowID.raw < $1.windowID.raw }) {
            showTiledBorder(target)
        }
        if borderWindow?.isVisible == true {
            borderWindow?.orderFrontRegardless()
        }
    }

    func hideTiledBorder(ifVisibleFor windowID: WindowID) {
        hideTiledBorder(windowID)
    }

    func hideFocusBorder(ifVisibleFor windowID: WindowID) {
        if focusBorderSuppression?.windowID == windowID {
            focusBorderSuppression = nil
        }
        guard visibleWindowID == windowID else { return }
        hideFocusBorder()
    }

    func debugFocusBorderWindowID() -> WindowID? {
        visibleWindowID
    }

    func debugFocusBorderIsVisible() -> Bool {
        borderWindow?.isVisible == true
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

    func debugTiledBorderLevelRawValue(for windowID: WindowID) -> Int? {
        tiledBorderWindows[windowID]?.level.rawValue
    }

    func stop() {
        hideFocusBorder()
        updateTiledBorders([])
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
        let duration = UInt64(max(0, hudConfig.durationMillis)) * 1_000_000
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
        window.orderFrontRegardless()
        borderWindow = window
        visibleWindowID = target.windowID
    }

    private func showTiledBorder(_ target: FocusBorderTarget) {
        let config = Self.tiledBorderConfig
        guard config.width > 0 else {
            hideTiledBorder(target.windowID)
            return
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
    }

    private func hideTiledBorder(_ windowID: WindowID) {
        tiledBorderWindows[windowID]?.orderOut(nil)
        tiledBorderWindows.removeValue(forKey: windowID)
        tiledBorderViews.removeValue(forKey: windowID)
    }

    private func hideFocusBorder() {
        borderWindow?.orderOut(nil)
        visibleWindowID = nil
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
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return window
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
        window.collectionBehavior = [.ignoresCycle]
        return window
    }

    private func orderTiledBorderWindow(_ window: NSWindow, above targetWindowID: WindowID) {
        window.order(.above, relativeTo: Int(targetWindowID.raw))
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
            cgFrame(for: lhs).intersection(frame).area < cgFrame(for: rhs).intersection(frame).area
        }) else {
            return frame
        }
        let displayFrame = cgFrame(for: screen)
        return CGRect(
            x: frame.minX,
            y: displayFrame.minY + (displayFrame.maxY - frame.maxY),
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
            cgFrame(for: lhs).intersection(frame).area < cgFrame(for: rhs).intersection(frame).area
        }) else {
            return false
        }
        let displayFrame = cgFrame(for: screen)
        return frame.matches(displayFrame, tolerance: tolerance)
            || frame.matches(axVisibleFrame(for: screen, displayFrame: displayFrame), tolerance: tolerance)
            || frame.fills(axVisibleFrame(for: screen, displayFrame: displayFrame), tolerance: 18, minimumAreaRatio: 0.96)
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
        if frame.matches(suppression.frame, tolerance: 18)
            || frame.fills(suppression.frame, tolerance: 18, minimumAreaRatio: 0.96) {
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
private final class HUDView: NSView {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let horizontalPadding: CGFloat = 18
    static let height: CGFloat = 38

    init(message: String, tone: OverlayTone) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = tone.background.cgColor
        layer?.borderColor = tone.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Self.font
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
private final class DragPreviewView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.70).cgColor
        label.layer?.cornerRadius = 4
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(title: String, valid: Bool) {
        label.stringValue = "  \(title)  "
        let stroke = valid ? NSColor.systemBlue : NSColor.systemRed
        layer?.backgroundColor = stroke.withAlphaComponent(valid ? 0.10 : 0.14).cgColor
        layer?.borderColor = stroke.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 2
    }
}

private extension OverlayTone {
    var background: NSColor {
        switch self {
        case .info:
            return NSColor.black.withAlphaComponent(0.82)
        case .success:
            return NSColor.systemGreen.withAlphaComponent(0.88)
        case .warning:
            return NSColor.systemOrange.withAlphaComponent(0.90)
        case .error:
            return NSColor.systemRed.withAlphaComponent(0.92)
        }
    }

    var border: NSColor {
        switch self {
        case .info:
            return NSColor.white.withAlphaComponent(0.18)
        case .success:
            return NSColor.white.withAlphaComponent(0.28)
        case .warning:
            return NSColor.white.withAlphaComponent(0.30)
        case .error:
            return NSColor.white.withAlphaComponent(0.34)
        }
    }
}

@MainActor
private final class CommandOverlayView: NSView {
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
            separatorFrame: columnsView.debugSeparatorFrame(in: columnsView.bounds)
        )
    }

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
        stack.alignment = .width
        stack.spacing = CommandOverlayLayout.stackSpacing
        addSubview(stack)

        let constraints: [NSLayoutConstraint] = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CommandOverlayLayout.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CommandOverlayLayout.horizontalPadding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: CommandOverlayLayout.topPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CommandOverlayLayout.bottomPadding),
            rowsFrame.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

@MainActor
private struct CommandOverlayDebugLayoutSnapshot {
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
}

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
    init(section: CommandOverlaySection, keyColumnWidth: CGFloat, commandColumnWidth: CGFloat) {
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

        let rows = section.rows.map { row in
            CommandRowView(
                key: row.key,
                command: row.command,
                detail: row.detail,
                keyColumnWidth: keyColumnWidth,
                commandColumnWidth: commandColumnWidth
            )
        }
        let rowStack = NSStackView(views: rows)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .width
        rowStack.spacing = CommandOverlayLayout.rowSpacing

        let stack = NSStackView(views: [headerStack, rowStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = CommandOverlayLayout.sectionHeaderSpacing
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: CommandOverlayLayout.sectionHeight(rowCount: section.rows.count))
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
private final class CommandRowView: NSView {
    init(key: String, command: String, detail: String, keyColumnWidth: CGFloat, commandColumnWidth: CGFloat) {
        super.init(frame: .zero)

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = CommandOverlayLayout.keyFont
        keyLabel.textColor = .white
        keyLabel.alignment = .left
        keyLabel.lineBreakMode = .byTruncatingMiddle
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let commandLabel = NSTextField(labelWithString: command)
        commandLabel.font = CommandOverlayLayout.commandFont
        commandLabel.textColor = NSColor.white.withAlphaComponent(0.90)
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = CommandOverlayLayout.detailFont
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.68)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let meaningStack = NSStackView(views: [commandLabel, detailLabel])
        meaningStack.translatesAutoresizingMaskIntoConstraints = false
        meaningStack.orientation = .vertical
        meaningStack.alignment = .width
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

    func debugColumnFrames(in bounds: CGRect) -> [CGRect] {
        CommandOverlayLayout.columnFrames(in: bounds, columnCount: columns.count).columns
    }

    func debugSeparatorFrame(in bounds: CGRect) -> CGRect? {
        CommandOverlayLayout.columnFrames(in: bounds, columnCount: columns.count).separator
    }
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
}

private struct CommandOverlayMetrics {
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

private enum CommandOverlayLayout {
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
    static let minimumKeyColumnWidth: CGFloat = 120
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

@MainActor
enum CommandOverlayVerification {
    static func verifyDefaultTwoColumnLayout() -> (passed: Bool, message: String) {
        let sections = commandOverlaySections(
            for: Config.default.keymap,
            dragModifier: Config.default.dragModifier,
            zones: Config.default.zones
        )
        let regularAvailableSize = CGSize(width: 2200, height: 760)
        let metrics = CommandOverlayMetrics.fitting(sections: sections, availableSize: regularAvailableSize)
        guard metrics.columns.count == 2 else {
            return (false, "expected 2 semantic command groups, got \(metrics.columns.count)")
        }
        guard sections.contains(where: { section in
            section.rows.contains(where: { $0.command == "Open Finder" })
        }) else {
            return (false, "default command overlay is missing Open Finder")
        }
        guard metrics.columns[1].first?.title == CommandOverlayCategory.system.title else {
            return (false, "default command overlay does not place System commands at the top of the right column")
        }
        let widestMeaningText = sections.flatMap(\.rows).map { row in
            max(
                CommandOverlayLayout.measure(row.command, font: CommandOverlayLayout.commandFont).width,
                CommandOverlayLayout.measure(row.detail, font: CommandOverlayLayout.detailFont).width
            )
        }.max() ?? 0
        guard widestMeaningText + CommandOverlayLayout.textFitPadding <= metrics.commandColumnWidth else {
            return (
                false,
                "default command overlay text would truncate: widest=\(widestMeaningText) column=\(metrics.commandColumnWidth)"
            )
        }

        let viewSize = CommandOverlayLayout.windowSize(
            forContentSize: metrics.contentSize,
            availableSize: regularAvailableSize
        )

        guard let snapshot = debugSnapshot(metrics: metrics, viewSize: viewSize) else {
            return (false, "command overlay did not produce a debug layout snapshot")
        }
        guard snapshot.titleText == CommandOverlayLayout.titleText else {
            return (false, "bad command overlay title: \(snapshot.titleText)")
        }
        let expectedTitleWidth = CommandOverlayLayout.measure(
            CommandOverlayLayout.titleText,
            font: CommandOverlayLayout.titleFont
        ).width
        guard snapshot.titleFrame.width >= expectedTitleWidth else {
            return (
                false,
                "command overlay title clipped: title=\(snapshot.titleFrame.debugDescription) expectedWidth=\(expectedTitleWidth)"
            )
        }
        guard snapshot.columnFrames.count == 2, let separator = snapshot.separatorFrame else {
            return (false, "expected 2 rendered columns with separator, got \(snapshot.columnFrames.count)")
        }

        let left = snapshot.columnFrames[0]
        let right = snapshot.columnFrames[1]
        let midX = snapshot.columnsBounds.midX
        let rightEdgeDelta = abs(right.maxX - snapshot.columnsBounds.maxX)
        let hasRealSplit = left.minX == snapshot.columnsBounds.minX
            && left.maxX < midX
            && separator.minX > left.maxX
            && separator.maxX < right.minX
            && right.minX > midX
            && rightEdgeDelta <= 1
        guard hasRealSplit else {
            return (
                false,
                "bad command overlay split: bounds=\(snapshot.columnsBounds.debugDescription) left=\(left.debugDescription) separator=\(separator.debugDescription) right=\(right.debugDescription)"
            )
        }
        guard snapshot.documentBounds.width <= snapshot.viewportBounds.width + 1,
              right.maxX <= snapshot.viewportBounds.maxX + 1
        else {
            return (
                false,
                "command overlay content clips horizontally: viewport=\(snapshot.viewportBounds.debugDescription) document=\(snapshot.documentBounds.debugDescription) right=\(right.debugDescription)"
            )
        }
        guard snapshot.scrollBarFrame.minX >= snapshot.scrollViewFrame.maxX + CommandOverlayLayout.scrollBarGap - 1 else {
            return (
                false,
                "command overlay scrollbar overlaps text area: scrollView=\(snapshot.scrollViewFrame.debugDescription) scrollBar=\(snapshot.scrollBarFrame.debugDescription)"
            )
        }
        guard !snapshot.scrollBarHidden,
              snapshot.scrollBarScrollable,
              snapshot.scrollBarFrame.width >= CommandOverlayLayout.scrollBarWidth - 1
        else {
            return (
                false,
                "command overlay scrollbar is not visible on first layout: hidden=\(snapshot.scrollBarHidden) scrollable=\(snapshot.scrollBarScrollable) frame=\(snapshot.scrollBarFrame.debugDescription) rowsHeight=\(metrics.rowsHeight) viewHeight=\(viewSize.height) viewport=\(snapshot.viewportBounds.debugDescription) document=\(snapshot.documentBounds.debugDescription)"
            )
        }

        let compactAvailableSize = CGSize(width: 760, height: 760)
        let regularWidthOnCompactScreen = CommandOverlayLayout.windowWidth(
            forContentSize: CommandOverlayMetrics(sections: sections).contentSize,
            availableHeight: compactAvailableSize.height
        )
        guard regularWidthOnCompactScreen > compactAvailableSize.width else {
            return (
                false,
                "compact verification width is too wide to trigger compact mode: required=\(regularWidthOnCompactScreen) available=\(compactAvailableSize.width)"
            )
        }
        let compactMetrics = CommandOverlayMetrics.fitting(sections: sections, availableSize: compactAvailableSize)
        guard compactMetrics.columns.count == 1 else {
            return (false, "narrow command overlay should use one column, got \(compactMetrics.columns.count)")
        }
        let compactViewSize = CommandOverlayLayout.windowSize(
            forContentSize: compactMetrics.contentSize,
            availableSize: compactAvailableSize
        )
        guard let compactSnapshot = debugSnapshot(metrics: compactMetrics, viewSize: compactViewSize) else {
            return (false, "compact command overlay did not produce a debug layout snapshot")
        }
        guard compactSnapshot.separatorFrame == nil,
              compactSnapshot.columnFrames.count == 1,
              let compactColumn = compactSnapshot.columnFrames.first
        else {
            return (
                false,
                "compact command overlay should render one column with no separator: columns=\(compactSnapshot.columnFrames.count) separator=\(String(describing: compactSnapshot.separatorFrame))"
            )
        }
        let compactRowWidth = compactMetrics.keyColumnWidth
            + CommandOverlayLayout.rowGap
            + compactMetrics.commandColumnWidth
        guard compactSnapshot.documentBounds.width <= compactSnapshot.viewportBounds.width + 1,
              compactColumn.maxX <= compactSnapshot.viewportBounds.maxX + 1,
              compactRowWidth <= compactColumn.width + 1
        else {
            return (
                false,
                "compact command overlay clips horizontally: viewport=\(compactSnapshot.viewportBounds.debugDescription) document=\(compactSnapshot.documentBounds.debugDescription) column=\(compactColumn.debugDescription) rowWidth=\(compactRowWidth)"
            )
        }
        guard !compactSnapshot.scrollBarHidden,
              compactSnapshot.scrollBarScrollable,
              compactSnapshot.scrollBarFrame.minX >= compactSnapshot.scrollViewFrame.maxX + CommandOverlayLayout.scrollBarGap - 1
        else {
            return (
                false,
                "compact command overlay scrollbar is missing or overlapping: hidden=\(compactSnapshot.scrollBarHidden) scrollable=\(compactSnapshot.scrollBarScrollable) scrollView=\(compactSnapshot.scrollViewFrame.debugDescription) scrollBar=\(compactSnapshot.scrollBarFrame.debugDescription)"
            )
        }

        return (
            true,
            "command overlay regular and compact layouts verified: regularViewport=\(snapshot.viewportBounds.debugDescription) compactViewport=\(compactSnapshot.viewportBounds.debugDescription) compactColumn=\(compactColumn.debugDescription)"
        )
    }

    private static func debugSnapshot(
        metrics: CommandOverlayMetrics,
        viewSize: CGSize
    ) -> CommandOverlayDebugLayoutSnapshot? {
        let view = CommandOverlayView(
            columns: metrics.columns,
            keyColumnWidth: metrics.keyColumnWidth,
            commandColumnWidth: metrics.commandColumnWidth,
            rowsHeight: metrics.rowsHeight
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: viewSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: viewSize)
        view.prepareForFirstDisplay()
        return view.debugLayoutSnapshot()
    }
}

@MainActor
enum FocusBorderVerification {
    static func verifyPerWindowCornerRadii() -> (passed: Bool, message: String) {
        let standardFrame = CGRect(x: 120, y: 90, width: 900, height: 640)
        let dialogFrame = CGRect(x: 200, y: 180, width: 460, height: 260)
        let utilityFrame = CGRect(x: 220, y: 210, width: 260, height: 160)
        let tinyFrame = CGRect(x: 20, y: 20, width: 24, height: 18)

        let standardRadius = focusBorderCornerRadius(frame: standardFrame, traits: .standard)
        let dialogRadius = focusBorderCornerRadius(
            frame: dialogFrame,
            traits: FocusBorderWindowTraits(
                role: "AXWindow",
                subrole: "AXDialog",
                isResizable: false,
                isFullscreen: false
            )
        )
        let utilityRadius = focusBorderCornerRadius(
            frame: utilityFrame,
            traits: FocusBorderWindowTraits(
                role: "AXWindow",
                subrole: "AXFloatingWindow",
                isResizable: false,
                isFullscreen: false
            )
        )
        let fullscreenRadius = focusBorderCornerRadius(
            frame: standardFrame,
            traits: FocusBorderWindowTraits(
                role: "AXWindow",
                subrole: "AXStandardWindow",
                isResizable: true,
                isFullscreen: true
            )
        )
        let tinyRadius = focusBorderCornerRadius(frame: tinyFrame, traits: .standard)

        guard standardRadius == 15 else {
            return (false, "expected standard focus radius 15, got \(standardRadius)")
        }
        guard dialogRadius < standardRadius, utilityRadius < dialogRadius else {
            return (
                false,
                "expected descending per-window radii, got standard=\(standardRadius) dialog=\(dialogRadius) utility=\(utilityRadius)"
            )
        }
        guard fullscreenRadius == 0 else {
            return (false, "expected fullscreen focus radius 0, got \(fullscreenRadius)")
        }
        guard tinyRadius <= Double(min(tinyFrame.width, tinyFrame.height)) / 2 else {
            return (false, "tiny focus radius exceeds half of the frame: radius=\(tinyRadius) frame=\(tinyFrame.debugDescription)")
        }

        let border = BorderConfig(width: 2, colorHex: "#4DA3FF")
        let view = BorderView(border: border, cornerRadius: standardRadius)
        let viewFrame = CGRect(origin: .zero, size: CGSize(width: standardFrame.width + border.width, height: standardFrame.height + border.width))
        view.frame = viewFrame
        view.layoutSubtreeIfNeeded()

        guard let standardSnapshot = view.debugGeometrySnapshot() else {
            return (false, "focus border view did not produce geometry")
        }
        guard standardSnapshot.renderedCornerRadius == standardRadius else {
            return (
                false,
                "rendered standard focus radius mismatch: requested=\(standardRadius) rendered=\(standardSnapshot.renderedCornerRadius)"
            )
        }
        guard standardSnapshot.pathBoundingBox.matches(standardSnapshot.strokeRect, tolerance: 1) else {
            return (
                false,
                "focus border path does not match stroke rect: path=\(standardSnapshot.pathBoundingBox.debugDescription) rect=\(standardSnapshot.strokeRect.debugDescription)"
            )
        }

        view.update(border: border, cornerRadius: utilityRadius)
        view.layoutSubtreeIfNeeded()
        guard let utilitySnapshot = view.debugGeometrySnapshot(),
              utilitySnapshot.renderedCornerRadius == utilityRadius else {
            return (false, "focus border view did not update to utility radius \(utilityRadius)")
        }

        let overlay = Overlay(border: border, hud: Config.default.hud)
        let visibleWindow = WindowID(raw: 901)
        let otherWindow = WindowID(raw: 902)
        overlay.updateFocusBorder(.show(FocusBorderTarget(
            windowID: visibleWindow,
            frame: standardFrame,
            cornerRadius: standardRadius
        )))
        guard overlay.debugFocusBorderWindowID() == visibleWindow,
              overlay.debugFocusBorderIsVisible() else {
            overlay.stop()
            return (false, "focus border overlay did not show for \(visibleWindow.description)")
        }

        overlay.hideFocusBorder(ifVisibleFor: otherWindow)
        guard overlay.debugFocusBorderWindowID() == visibleWindow,
              overlay.debugFocusBorderIsVisible() else {
            overlay.stop()
            return (false, "focus border overlay hid for unrelated closed window \(otherWindow.description)")
        }

        overlay.hideFocusBorder(ifVisibleFor: visibleWindow)
        guard overlay.debugFocusBorderWindowID() == nil,
              !overlay.debugFocusBorderIsVisible() else {
            overlay.stop()
            return (false, "focus border overlay stayed visible after closing \(visibleWindow.description)")
        }
        overlay.stop()

        let tiledOverlay = Overlay(border: border, hud: Config.default.hud)
        let firstTargetWindow = makeVerificationWindow(
            frame: CGRect(x: 10, y: 10, width: 420, height: 320),
            color: .systemGray
        )
        let secondTargetWindow = makeVerificationWindow(
            frame: CGRect(x: 460, y: 10, width: 420, height: 320),
            color: .systemBlue
        )
        defer {
            firstTargetWindow.orderOut(nil)
            secondTargetWindow.orderOut(nil)
        }
        firstTargetWindow.orderFrontRegardless()
        secondTargetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        let firstTiled = WindowID(raw: CGWindowID(firstTargetWindow.windowNumber))
        let secondTiled = WindowID(raw: CGWindowID(secondTargetWindow.windowNumber))
        let expectedTiledIDs = [firstTiled, secondTiled].sorted { $0.raw < $1.raw }
        tiledOverlay.updateTiledBorders([
            FocusBorderTarget(
                windowID: firstTiled,
                frame: CGRect(x: 10, y: 10, width: 420, height: 320),
                cornerRadius: standardRadius
            ),
            FocusBorderTarget(
                windowID: secondTiled,
                frame: CGRect(x: 460, y: 10, width: 420, height: 320),
                cornerRadius: dialogRadius
            )
        ])
        guard tiledOverlay.debugTiledBorderWindowIDs() == expectedTiledIDs,
              tiledOverlay.debugVisibleTiledBorderCount() == 2 else {
            tiledOverlay.stop()
            return (false, "tiled border overlay did not show both tiled windows")
        }

        guard let initialSecondFrame = tiledOverlay.debugTiledBorderFrame(for: secondTiled) else {
            tiledOverlay.stop()
            return (false, "tiled border overlay did not expose the initial second tiled border frame")
        }
        let updatedSecondFrame = CGRect(x: 500, y: 30, width: 520, height: 280)
        tiledOverlay.updateTiledBorders([
            FocusBorderTarget(
                windowID: firstTiled,
                frame: CGRect(x: 10, y: 10, width: 420, height: 320),
                cornerRadius: standardRadius
            ),
            FocusBorderTarget(
                windowID: secondTiled,
                frame: updatedSecondFrame,
                cornerRadius: dialogRadius
            )
        ])
        guard let renderedSecondFrame = tiledOverlay.debugTiledBorderFrame(for: secondTiled),
              renderedSecondFrame.minX == updatedSecondFrame.minX - 1,
              renderedSecondFrame.minX != initialSecondFrame.minX,
              renderedSecondFrame.width == updatedSecondFrame.width + 2,
              renderedSecondFrame.height == updatedSecondFrame.height + 2 else {
            tiledOverlay.stop()
            return (
                false,
                "tiled border overlay did not move and resize an existing tiled border: rendered=\(String(describing: tiledOverlay.debugTiledBorderFrame(for: secondTiled))) expectedTarget=\(updatedSecondFrame.debugDescription)"
            )
        }

        tiledOverlay.hideTiledBorder(ifVisibleFor: firstTiled)
        guard tiledOverlay.debugTiledBorderWindowIDs() == [secondTiled],
              tiledOverlay.debugVisibleTiledBorderCount() == 1 else {
            tiledOverlay.stop()
            return (false, "tiled border overlay did not hide closed tiled window \(firstTiled.description)")
        }

        tiledOverlay.updateTiledBorders([])
        guard tiledOverlay.debugTiledBorderWindowIDs().isEmpty,
              tiledOverlay.debugVisibleTiledBorderCount() == 0 else {
            tiledOverlay.stop()
            return (false, "tiled border overlay did not clear all tiled borders")
        }

        tiledOverlay.updateTiledBorders([
            FocusBorderTarget(
                windowID: firstTiled,
                frame: CGRect(x: 10, y: 10, width: 420, height: 320),
                cornerRadius: standardRadius
            ),
            FocusBorderTarget(
                windowID: secondTiled,
                frame: CGRect(x: 460, y: 10, width: 420, height: 320),
                cornerRadius: dialogRadius
            )
        ])
        guard tiledOverlay.debugTiledBorderWindowIDs() == expectedTiledIDs,
              tiledOverlay.debugVisibleTiledBorderCount() == 2 else {
            tiledOverlay.stop()
            return (false, "tiled border overlay did not show tiled windows after a clear")
        }
        tiledOverlay.stop()

        let stacking = verifyTiledBorderStacking(cornerRadius: standardRadius)
        guard stacking.passed else {
            return stacking
        }

        return (
            true,
            "focus/tiled borders verified: focus standard=\(standardRadius) dialog=\(dialogRadius) utility=\(utilityRadius) tiny=\(tinyRadius) path=\(standardSnapshot.pathBoundingBox.debugDescription); \(stacking.message)"
        )
    }

    private static func verifyTiledBorderStacking(cornerRadius: Double) -> (passed: Bool, message: String) {
        let targetFrame = CGRect(x: 120, y: 120, width: 300, height: 220)
        let coverFrame = CGRect(x: 140, y: 140, width: 260, height: 180)
        let targetWindow = makeVerificationWindow(frame: targetFrame, color: .systemGray)
        let coverWindow = makeVerificationWindow(frame: coverFrame, color: .systemRed)
        let overlay = Overlay(border: BorderConfig(width: 2, colorHex: "#4DA3FF"), hud: Config.default.hud)
        defer {
            overlay.stop()
            targetWindow.orderOut(nil)
            coverWindow.orderOut(nil)
        }

        targetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        let targetID = WindowID(raw: CGWindowID(targetWindow.windowNumber))
        overlay.updateTiledBorders([
            FocusBorderTarget(windowID: targetID, frame: targetFrame, cornerRadius: cornerRadius)
        ])
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        coverWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        guard overlay.debugTiledBorderLevelRawValue(for: targetID) == NSWindow.Level.normal.rawValue else {
            return (false, "tiled border window was not at normal window level")
        }
        guard let borderNumber = overlay.debugTiledBorderWindowNumber(for: targetID) else {
            return (false, "tiled border window did not expose a window number")
        }
        guard let orderedWindowNumbers = frontToBackWindowNumbers(),
              let coverIndex = orderedWindowNumbers.firstIndex(of: coverWindow.windowNumber),
              let borderIndex = orderedWindowNumbers.firstIndex(of: borderNumber),
              let targetIndex = orderedWindowNumbers.firstIndex(of: targetWindow.windowNumber)
        else {
            return (false, "could not verify tiled border window-server stacking")
        }
        guard coverIndex < borderIndex, borderIndex < targetIndex else {
            return (
                false,
                "tiled border stacking is wrong: coverIndex=\(coverIndex) borderIndex=\(borderIndex) targetIndex=\(targetIndex)"
            )
        }

        targetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        overlay.updateTiledBorders([
            FocusBorderTarget(windowID: targetID, frame: targetFrame, cornerRadius: cornerRadius)
        ])
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        guard let focusedOrderedWindowNumbers = frontToBackWindowNumbers(),
              let focusedBorderIndex = focusedOrderedWindowNumbers.firstIndex(of: borderNumber),
              let focusedTargetIndex = focusedOrderedWindowNumbers.firstIndex(of: targetWindow.windowNumber)
        else {
            return (false, "could not verify focused tiled border window-server stacking")
        }
        guard focusedBorderIndex < focusedTargetIndex else {
            return (
                false,
                "focused tiled border stayed behind target: borderIndex=\(focusedBorderIndex) targetIndex=\(focusedTargetIndex)"
            )
        }

        return (
            true,
            "tiled border stacking verified cover=\(coverWindow.windowNumber) border=\(borderNumber) target=\(targetWindow.windowNumber)"
        )
    }

    private static func makeVerificationWindow(frame: CGRect, color: NSColor) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = color
        window.isOpaque = true
        window.hasShadow = false
        window.level = .normal
        window.collectionBehavior = [.ignoresCycle]
        return window
    }

    private static func frontToBackWindowNumbers() -> [Int]? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else { return nil }

        return windows.compactMap { window in
            if let number = window[kCGWindowNumber as String] as? CGWindowID {
                return Int(number)
            }
            if let number = window[kCGWindowNumber as String] as? Int {
                return number
            }
            return nil
        }
    }
}

@MainActor
private struct FocusBorderDebugGeometrySnapshot {
    let strokeRect: CGRect
    let requestedCornerRadius: Double
    let renderedCornerRadius: Double
    let pathBoundingBox: CGRect
}

@MainActor
private final class BorderView: NSView {
    private let shapeLayer = CAShapeLayer()
    private var border: BorderConfig
    private var cornerRadius: Double
    private var strokeRect: CGRect = .zero
    private var renderedCornerRadius: Double = 0

    init(border: BorderConfig, cornerRadius: Double) {
        self.border = border
        self.cornerRadius = max(0, cornerRadius)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        shapeLayer.fillColor = NSColor.clear.cgColor
        shapeLayer.lineJoin = .round
        shapeLayer.lineCap = .round
        layer?.addSublayer(shapeLayer)
        update(border: border)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        updatePath()
    }

    func update(border: BorderConfig, cornerRadius: Double? = nil) {
        self.border = border
        if let cornerRadius {
            self.cornerRadius = max(0, cornerRadius)
        }
        shapeLayer.strokeColor = NSColor(hexRGB: border.colorHex)?.cgColor ?? NSColor.systemBlue.cgColor
        shapeLayer.lineWidth = border.width
        shapeLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        updatePath()
    }

    func debugGeometrySnapshot() -> FocusBorderDebugGeometrySnapshot? {
        layoutSubtreeIfNeeded()
        guard let path = shapeLayer.path else {
            return nil
        }
        return FocusBorderDebugGeometrySnapshot(
            strokeRect: strokeRect,
            requestedCornerRadius: cornerRadius,
            renderedCornerRadius: renderedCornerRadius,
            pathBoundingBox: path.boundingBox
        )
    }

    private func updatePath() {
        shapeLayer.frame = bounds
        let strokeInset = border.width / 2
        let rect = bounds.insetBy(dx: strokeInset, dy: strokeInset)
        let radius = min(cornerRadius, max(0, Double(min(rect.width, rect.height)) / 2))
        strokeRect = rect
        renderedCornerRadius = radius
        shapeLayer.path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }
}

private func describe(_ key: KeySpec) -> String {
    let modifiers = [
        key.modifiers.contains(.control) ? "control" : nil,
        key.modifiers.contains(.option) ? "option" : nil,
        key.modifiers.contains(.shift) ? "shift" : nil,
        key.modifiers.contains(.command) ? "command" : nil
    ].compactMap { $0 }
    return (modifiers + [key.key.uppercased()]).joined(separator: "-")
}

private func describe(_ modifiers: ModifierSet) -> String {
    let values = [
        modifiers.contains(.control) ? "control" : nil,
        modifiers.contains(.option) ? "option" : nil,
        modifiers.contains(.shift) ? "shift" : nil,
        modifiers.contains(.command) ? "command" : nil
    ].compactMap { $0 }
    return values.isEmpty ? "drag" : values.joined(separator: "-")
}

private func describe(_ action: HotkeyAction) -> String {
    commandOverlayDescription(for: action)
}

private func describe(_ template: CommandTemplate) -> String {
    commandOverlayDescription(for: .command(template))
}

private struct CommandOverlaySection {
    let title: String
    let purpose: String
    let rows: [CommandOverlayRow]
}

private struct CommandOverlayRow {
    let key: String
    let command: String
    let detail: String
}

private enum CommandOverlayCategory: CaseIterable {
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

private func commandOverlaySections(
    for bindings: [HotkeyBinding],
    dragModifier: ModifierSet,
    zones: [Zone]
) -> [CommandOverlaySection] {
    var rowsByCategory: [CommandOverlayCategory: [CommandOverlayRow]] = [:]
    for binding in bindings {
        let category = commandOverlayCategory(for: binding.action)
        rowsByCategory[category, default: []].append(CommandOverlayRow(
            key: describe(binding.key),
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
    let gesture = modifier.isEmpty ? "drag" : "\(describe(modifier))-drag"
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
                key: "control-option-J",
                command: "Scroll down",
                detail: "Scroll this overlay down without moving window focus"
            ),
            CommandOverlayRow(
                key: "control-option-K",
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
        case .swap, .resizeSplit, .balance, .shuffle, .cascade, .undoLayout:
            return .arrangement
        case .togglePause, .resetLayout:
            return .system
        }
    case .openFinderWindow, .reloadConfig, .showCommands:
        return .system
    }
}

private func commandOverlayDescription(for action: HotkeyAction) -> String {
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

private func commandOverlayCommand(for action: HotkeyAction) -> String {
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

private extension NSColor {
    convenience init?(hexRGB: String) {
        let raw = hexRGB.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    func matches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    func fills(_ other: CGRect, tolerance: CGFloat, minimumAreaRatio: CGFloat) -> Bool {
        guard width > 0, height > 0, other.width > 0, other.height > 0 else { return false }
        let expanded = other.insetBy(dx: -tolerance, dy: -tolerance)
        guard minX >= expanded.minX,
              minY >= expanded.minY,
              maxX <= expanded.maxX,
              maxY <= expanded.maxY
        else { return false }
        return area / other.area >= minimumAreaRatio
    }
}
