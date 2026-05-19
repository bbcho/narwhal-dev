import AppKit
import QuartzCore
import WinMgrCore

@MainActor
final class Overlay {
    private var borderConfig: BorderConfig
    private var hudConfig: HUDConfig
    private var borderWindow: NSWindow?
    private var borderView: BorderView?
    private var commandWindow: NSWindow?
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
        case .show(let windowID, let frame):
            showFocusBorder(windowID: windowID, frame: frame)
        case .hide:
            hideFocusBorder()
        }
    }

    func stop() {
        hideFocusBorder()
        hideCommandOverlay()
    }

    func toggleCommandOverlay(bindings: [HotkeyBinding]) {
        if commandWindow?.isVisible == true {
            hideCommandOverlay()
        } else {
            showCommandOverlay(bindings: bindings)
        }
    }

    private func showFocusBorder(windowID: WindowID, frame: CGRect) {
        guard borderConfig.width > 0 else {
            hideFocusBorder()
            return
        }

        let appKitFrame = appKitFrame(forAXFrame: frame).insetBy(dx: -borderConfig.width / 2, dy: -borderConfig.width / 2)
        let window = borderWindow ?? makeBorderWindow(frame: appKitFrame)
        let view = borderView ?? BorderView(border: borderConfig)
        if borderView == nil {
            window.contentView = view
            borderView = view
        }
        view.update(border: borderConfig)
        window.setFrame(appKitFrame, display: true)
        window.orderFrontRegardless()
        borderWindow = window
        visibleWindowID = windowID
    }

    private func hideFocusBorder() {
        borderWindow?.orderOut(nil)
        visibleWindowID = nil
    }

    private func showCommandOverlay(bindings: [HotkeyBinding]) {
        let metrics = CommandOverlayMetrics(bindings: bindings)
        let frame = commandOverlayFrame(on: commandOverlayScreen(), contentSize: metrics.contentSize)
        let window = commandWindow ?? makeCommandWindow(frame: frame)
        window.contentView = CommandOverlayView(
            bindings: bindings,
            keyColumnWidth: metrics.keyColumnWidth,
            rowsHeight: metrics.rowsHeight
        )
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        commandWindow = window
    }

    private func hideCommandOverlay() {
        commandWindow?.orderOut(nil)
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

    private func commandOverlayScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func commandOverlayFrame(on screen: NSScreen?, contentSize: CGSize) -> CGRect {
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 900, height: 700)
        let availableWidth = max(1, visibleFrame.width - CommandOverlayLayout.screenMargin * 2)
        let availableHeight = max(1, visibleFrame.height - CommandOverlayLayout.screenMargin * 2)
        let width = min(contentSize.width, availableWidth)
        let height = min(contentSize.height, availableHeight)
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
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
}

@MainActor
private final class CommandOverlayView: NSView {
    private let rowsHeight: CGFloat
    private weak var scrollView: NSScrollView?
    private weak var rowsDocumentView: NSView?

    init(bindings: [HotkeyBinding], keyColumnWidth: CGFloat, rowsHeight: CGFloat) {
        self.rowsHeight = rowsHeight
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        build(bindings: bindings, keyColumnWidth: keyColumnWidth)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        guard let scrollView, let rowsDocumentView else { return }
        rowsDocumentView.setFrameSize(NSSize(width: scrollView.contentView.bounds.width, height: rowsHeight))
    }

    private func build(bindings: [HotkeyBinding], keyColumnWidth: CGFloat) {
        let title = NSTextField(labelWithString: "WinMgr Commands")
        title.font = CommandOverlayLayout.titleFont
        title.textColor = .white

        let subtitle = NSTextField(labelWithString: "Press the shortcut again to hide this overlay.")
        subtitle.font = CommandOverlayLayout.subtitleFont
        subtitle.textColor = NSColor.white.withAlphaComponent(0.72)

        let rows = bindings.map { binding in
            CommandRowView(key: describe(binding.key), action: describe(binding.action), keyColumnWidth: keyColumnWidth)
        }
        let rowStack = NSStackView(views: rows)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = CommandOverlayLayout.rowSpacing

        let documentView = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 1, height: rowsHeight))
        documentView.addSubview(rowStack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        self.scrollView = scrollView
        self.rowsDocumentView = documentView

        let stack = NSStackView(views: [title, subtitle, scrollView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CommandOverlayLayout.stackSpacing
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CommandOverlayLayout.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CommandOverlayLayout.horizontalPadding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: CommandOverlayLayout.topPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CommandOverlayLayout.bottomPadding),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rowStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
    }
}

@MainActor
private final class CommandRowView: NSView {
    init(key: String, action: String, keyColumnWidth: CGFloat) {
        super.init(frame: .zero)

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = CommandOverlayLayout.keyFont
        keyLabel.textColor = .white
        keyLabel.alignment = .right
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let actionLabel = NSTextField(labelWithString: action)
        actionLabel.font = CommandOverlayLayout.actionFont
        actionLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        actionLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [keyLabel, actionLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = CommandOverlayLayout.rowGap
        addSubview(stack)

        NSLayoutConstraint.activate([
            keyLabel.widthAnchor.constraint(equalToConstant: keyColumnWidth),
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

private struct CommandOverlayMetrics {
    let contentSize: CGSize
    let keyColumnWidth: CGFloat
    let rowsHeight: CGFloat

    init(bindings: [HotkeyBinding]) {
        let keyTexts = bindings.map { describe($0.key) }
        let actionTexts = bindings.map { describe($0.action) }
        let measuredKeyWidth = keyTexts.map {
            CommandOverlayLayout.measure($0, font: CommandOverlayLayout.keyFont).width
        }.max() ?? 0
        let measuredActionWidth = actionTexts.map {
            CommandOverlayLayout.measure($0, font: CommandOverlayLayout.actionFont).width
        }.max() ?? 0

        keyColumnWidth = ceil(max(CommandOverlayLayout.minimumKeyColumnWidth, measuredKeyWidth))
        rowsHeight = CommandOverlayLayout.rowsHeight(count: bindings.count)

        let titleWidth = CommandOverlayLayout.measure("WinMgr Commands", font: CommandOverlayLayout.titleFont).width
        let subtitleWidth = CommandOverlayLayout.measure(
            "Press the shortcut again to hide this overlay.",
            font: CommandOverlayLayout.subtitleFont
        ).width
        let commandWidth = keyColumnWidth + CommandOverlayLayout.rowGap + ceil(measuredActionWidth)
        let contentWidth = CommandOverlayLayout.horizontalPadding * 2 + max(titleWidth, subtitleWidth, commandWidth)
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
    static let screenMargin: CGFloat = 24
    static let horizontalPadding: CGFloat = 32
    static let topPadding: CGFloat = 28
    static let bottomPadding: CGFloat = 28
    static let stackSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 8
    static let rowGap: CGFloat = 18
    static let rowHeight: CGFloat = 22
    static let minimumKeyColumnWidth: CGFloat = 120
    static let titleFont = NSFont.systemFont(ofSize: 24, weight: .semibold)
    static let subtitleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let keyFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
    static let actionFont = NSFont.systemFont(ofSize: 15, weight: .regular)

    static func rowsHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * rowHeight + CGFloat(count - 1) * rowSpacing
    }

    static func measure(_ text: String, font: NSFont) -> CGSize {
        let attributed = text as NSString
        return attributed.size(withAttributes: [.font: font])
    }

    static func lineHeight(font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}

@MainActor
private final class BorderView: NSView {
    private static let macWindowCornerRadius: CGFloat = 10

    private let shapeLayer = CAShapeLayer()
    private var border: BorderConfig

    init(border: BorderConfig) {
        self.border = border
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

    func update(border: BorderConfig) {
        self.border = border
        shapeLayer.strokeColor = NSColor(hexRGB: border.colorHex)?.cgColor ?? NSColor.systemBlue.cgColor
        shapeLayer.lineWidth = border.width
        shapeLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        updatePath()
    }

    private func updatePath() {
        shapeLayer.frame = bounds
        let strokeInset = border.width / 2
        let rect = bounds.insetBy(dx: strokeInset, dy: strokeInset)
        let radius = min(
            Self.macWindowCornerRadius + strokeInset,
            min(rect.width, rect.height) / 2
        )
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

private func describe(_ action: HotkeyAction) -> String {
    switch action {
    case .command(let template):
        return describe(template)
    case .reloadConfig:
        return "Reload config"
    case .showCommands:
        return "Show commands"
    }
}

private func describe(_ template: CommandTemplate) -> String {
    switch template {
    case .push(let direction):
        return "Push focused window \(direction.rawValue)"
    case .center:
        return "Center focused window"
    case .eject:
        return "Float focused tiled window"
    case .swap(let direction):
        return "Swap focused window \(direction.rawValue)"
    case .resizeSplit(let direction, let delta):
        return "Resize split \(direction.rawValue) by \(delta)"
    case .focusDirection(let direction):
        return "Focus window \(direction.rawValue)"
    case .focusCycle(let direction):
        return "Focus \(direction.rawValue) visible window"
    case .toggleFloat:
        return "Toggle focused window floating"
    case .balance:
        return "Balance active Space"
    case .resetLayout:
        return "Reset layout memory"
    }
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
}
