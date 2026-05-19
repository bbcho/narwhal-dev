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
        let sections = commandOverlaySections(for: bindings)
        let metrics = CommandOverlayMetrics(sections: sections)
        let frame = commandOverlayFrame(on: commandOverlayScreen(), contentSize: metrics.contentSize)
        let window = commandWindow ?? makeCommandWindow(frame: frame)
        window.contentView = CommandOverlayView(
            sections: sections,
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

    init(sections: [CommandOverlaySection], keyColumnWidth: CGFloat, rowsHeight: CGFloat) {
        self.rowsHeight = rowsHeight
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        build(sections: sections, keyColumnWidth: keyColumnWidth)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        guard let scrollView, let rowsDocumentView else { return }
        rowsDocumentView.setFrameSize(NSSize(width: scrollView.contentView.bounds.width, height: rowsHeight))
    }

    private func build(sections: [CommandOverlaySection], keyColumnWidth: CGFloat) {
        let title = NSTextField(labelWithString: "WinMgr Commands")
        title.font = CommandOverlayLayout.titleFont
        title.textColor = .white

        let subtitle = NSTextField(labelWithString: "Active shortcuts grouped by what they do.")
        subtitle.font = CommandOverlayLayout.subtitleFont
        subtitle.textColor = NSColor.white.withAlphaComponent(0.72)

        let sectionViews = sections.map { section in
            CommandSectionView(section: section, keyColumnWidth: keyColumnWidth)
        }
        let sectionStack = NSStackView(views: sectionViews)
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = CommandOverlayLayout.sectionSpacing

        let documentView = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 1, height: rowsHeight))
        documentView.addSubview(sectionStack)

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
            sectionStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            sectionStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            sectionStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            sectionStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
    }
}

@MainActor
private final class CommandSectionView: NSView {
    init(section: CommandOverlaySection, keyColumnWidth: CGFloat) {
        super.init(frame: .zero)

        let header = NSTextField(labelWithString: section.title)
        header.font = CommandOverlayLayout.sectionFont
        header.textColor = NSColor.white.withAlphaComponent(0.58)
        header.setContentCompressionResistancePriority(.required, for: .horizontal)

        let rows = section.rows.map { row in
            CommandRowView(key: row.key, action: row.action, keyColumnWidth: keyColumnWidth)
        }
        let rowStack = NSStackView(views: rows)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = CommandOverlayLayout.rowSpacing

        let stack = NSStackView(views: [header, rowStack])
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

    init(sections: [CommandOverlaySection]) {
        let rows = sections.flatMap(\.rows)
        let keyTexts = rows.map(\.key)
        let actionTexts = rows.map(\.action)
        let measuredKeyWidth = keyTexts.map {
            CommandOverlayLayout.measure($0, font: CommandOverlayLayout.keyFont).width
        }.max() ?? 0
        let measuredActionWidth = actionTexts.map {
            CommandOverlayLayout.measure($0, font: CommandOverlayLayout.actionFont).width
        }.max() ?? 0
        let measuredSectionWidth = sections.map {
            CommandOverlayLayout.measure($0.title, font: CommandOverlayLayout.sectionFont).width
        }.max() ?? 0

        keyColumnWidth = ceil(max(CommandOverlayLayout.minimumKeyColumnWidth, measuredKeyWidth))
        rowsHeight = CommandOverlayLayout.sectionsHeight(sections)

        let titleWidth = CommandOverlayLayout.measure("WinMgr Commands", font: CommandOverlayLayout.titleFont).width
        let subtitleWidth = CommandOverlayLayout.measure(
            "Active shortcuts grouped by what they do.",
            font: CommandOverlayLayout.subtitleFont
        ).width
        let commandWidth = keyColumnWidth + CommandOverlayLayout.rowGap + ceil(measuredActionWidth)
        let contentWidth = CommandOverlayLayout.horizontalPadding * 2 + max(
            titleWidth,
            subtitleWidth,
            measuredSectionWidth,
            commandWidth
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
    static let screenMargin: CGFloat = 24
    static let horizontalPadding: CGFloat = 32
    static let topPadding: CGFloat = 28
    static let bottomPadding: CGFloat = 28
    static let stackSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 18
    static let sectionHeaderSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 8
    static let rowGap: CGFloat = 18
    static let rowHeight: CGFloat = 22
    static let sectionHeaderHeight: CGFloat = 16
    static let minimumKeyColumnWidth: CGFloat = 120
    static let titleFont = NSFont.systemFont(ofSize: 24, weight: .semibold)
    static let subtitleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let sectionFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let keyFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
    static let actionFont = NSFont.systemFont(ofSize: 15, weight: .regular)

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
    commandOverlayDescription(for: action)
}

private func describe(_ template: CommandTemplate) -> String {
    commandOverlayDescription(for: .command(template))
}

private struct CommandOverlaySection {
    let title: String
    let rows: [CommandOverlayRow]
}

private struct CommandOverlayRow {
    let key: String
    let action: String
}

private enum CommandOverlayCategory: CaseIterable {
    case movement
    case placement
    case arrangement
    case system

    var title: String {
        switch self {
        case .movement:
            return "Movement"
        case .placement:
            return "Window Placement"
        case .arrangement:
            return "Layout Arrangement"
        case .system:
            return "System"
        }
    }
}

private func commandOverlaySections(for bindings: [HotkeyBinding]) -> [CommandOverlaySection] {
    var rowsByCategory: [CommandOverlayCategory: [CommandOverlayRow]] = [:]
    for binding in bindings {
        let category = commandOverlayCategory(for: binding.action)
        rowsByCategory[category, default: []].append(CommandOverlayRow(
            key: describe(binding.key),
            action: commandOverlayDescription(for: binding.action)
        ))
    }

    let sections = CommandOverlayCategory.allCases.compactMap { category -> CommandOverlaySection? in
        guard let rows = rowsByCategory[category], !rows.isEmpty else { return nil }
        return CommandOverlaySection(title: category.title, rows: rows)
    }
    if !sections.isEmpty {
        return sections
    }
    return [
        CommandOverlaySection(
            title: "System",
            rows: [CommandOverlayRow(key: "", action: "No active command shortcuts in the current config")]
        )
    ]
}

private func commandOverlayCategory(for action: HotkeyAction) -> CommandOverlayCategory {
    switch action {
    case .command(let template):
        switch template {
        case .focusDirection, .focusCycle:
            return .movement
        case .push, .center, .eject, .toggleFloat:
            return .placement
        case .swap, .resizeSplit, .balance:
            return .arrangement
        case .resetLayout:
            return .system
        }
    case .reloadConfig, .showCommands:
        return .system
    }
}

private func commandOverlayDescription(for action: HotkeyAction) -> String {
    switch action {
    case .command(let template):
        return commandOverlayDescription(for: template)
    case .reloadConfig:
        return "Reload config and rebind shortcuts"
    case .showCommands:
        return "Show or hide this command overlay"
    }
}

private func commandOverlayDescription(for template: CommandTemplate) -> String {
    switch template {
    case .push(let direction):
        return "Tile focused window into the \(edgeName(direction)) lane"
    case .center:
        return "Tile focused window into the center lane"
    case .eject:
        return "Remove focused tiled window from the layout and leave it floating"
    case .swap(let direction):
        return "Swap focused tiled window with the nearest tiled neighbor \(neighborName(direction))"
    case .resizeSplit(let direction, let delta):
        return resizeDescription(direction: direction, delta: delta)
    case .focusDirection(let direction):
        return "Move focus to the nearest tiled window \(neighborName(direction))"
    case .focusCycle(let direction):
        return "Focus the \(direction.rawValue) visible window in screen order"
    case .toggleFloat:
        return "If tiled, float focused window; if floating, tile it in the center"
    case .balance:
        return "Reset active Space split weights to equal sizes"
    case .resetLayout:
        return "Clear tiling state, floating order, focus memory, and constraints"
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
}
