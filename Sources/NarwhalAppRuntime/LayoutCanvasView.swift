import AppKit
import NarwhalAppSupport
import NarwhalCore

struct LayoutCanvasGeometrySnapshot: Equatable {
    let displayRect: CGRect
    let windowRects: [WindowID: CGRect]
    let previewRects: [WindowID: CGRect]
    let emptyRects: [CGRect]
}

@MainActor
final class LayoutCanvasView: NSView {
    var workspace: WorkspacePresentation? {
        didSet { needsDisplay = true }
    }
    var preview: CommandPreview? {
        didSet { needsDisplay = true }
    }
    var selectedWindowID: WindowID? {
        didSet { needsDisplay = true }
    }
    var onSelectWindow: ((WindowID?) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Layout geometry canvas")
        setAccessibilityHelp("Selects a window for inspection without changing macOS focus")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let workspace else {
            drawCenteredMessage("No workspace selected", in: bounds)
            return
        }
        let geometry = geometrySnapshot()
        drawDisplay(geometry.displayRect, workspace: workspace)
        for emptyRect in geometry.emptyRects {
            drawEmptyCell(emptyRect)
        }
        for window in workspace.windows {
            guard let rect = geometry.windowRects[window.id] else { continue }
            drawWindow(window, rect: rect)
        }
        drawPreviews(geometry.previewRects, baseline: geometry.windowRects)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let geometry = geometrySnapshot()
        let selected = geometry.windowRects
            .filter { $0.value.contains(point) }
            .sorted { lhs, rhs in
                let leftArea = lhs.value.width * lhs.value.height
                let rightArea = rhs.value.width * rhs.value.height
                return leftArea == rightArea ? lhs.key.raw < rhs.key.raw : leftArea < rightArea
            }
            .first?.key
        selectedWindowID = selected
        onSelectWindow?(selected)
    }

    func geometrySnapshot() -> LayoutCanvasGeometrySnapshot {
        guard let workspace else {
            return LayoutCanvasGeometrySnapshot(displayRect: .zero, windowRects: [:], previewRects: [:], emptyRects: [])
        }
        let displayRect = fittedDisplayRect(for: workspace.visibleFrame, in: bounds.insetBy(dx: 24, dy: 24))
        let transform: (CGRect) -> CGRect = { [workspace] frame in
            map(frame, from: workspace.visibleFrame, to: displayRect)
        }
        let windowRects = Dictionary(
            uniqueKeysWithValues: workspace.windows.map { ($0.id, transform($0.frame)) }
        )
        let previewRects = Dictionary(
            uniqueKeysWithValues: (preview?.proposedLayout.tiled ?? [:]).map { ($0.key, transform($0.value)) }
        )
        let emptyRects = treeCells(
            workspace.tree,
            frame: workspace.visibleFrame
        ).compactMap { node, frame in
            node == .void ? transform(frame) : nil
        }
        return LayoutCanvasGeometrySnapshot(
            displayRect: displayRect,
            windowRects: windowRects,
            previewRects: previewRects,
            emptyRects: emptyRects
        )
    }

    private func drawDisplay(_ rect: CGRect, workspace: WorkspacePresentation) {
        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.stroke()

        let status = workspace.isActive ? "ACTIVE" : "INACTIVE"
        drawText(
            "DISPLAY \(workspace.displaySlot)  •  SPACE \(workspace.key.spaceID.raw)  •  \(status)",
            at: CGPoint(x: rect.minX + 8, y: rect.minY + 7),
            color: .secondaryLabelColor,
            font: .monospacedSystemFont(ofSize: 10, weight: .medium)
        )
    }

    private func drawWindow(_ window: WindowPresentation, rect: CGRect) {
        let tileRect = rect.insetBy(dx: 2, dy: 2)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: tileRect, xRadius: 4, yRadius: 4).fill()

        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        let strokeColor = selectedWindowID == window.id ? NSColor.labelColor : borderColor(for: window)
        context?.setStrokeColor(strokeColor.cgColor)
        context?.setLineWidth(selectedWindowID == window.id ? 3 : 2)
        context?.setLineDash(phase: 0, lengths: dashPattern(for: window.state))
        context?.stroke(tileRect.insetBy(dx: 1, dy: 1))
        context?.restoreGState()

        if window.state == .manualAdjustment {
            NSColor.systemOrange.setStroke()
            let inner = NSBezierPath(roundedRect: tileRect.insetBy(dx: 4, dy: 4), xRadius: 3, yRadius: 3)
            inner.lineWidth = 1
            inner.stroke()
        }

        let title = truncated(window.title, limit: 30)
        drawText(
            title,
            at: CGPoint(x: tileRect.minX + 7, y: tileRect.minY + 7),
            color: .labelColor,
            font: .systemFont(ofSize: 11, weight: .medium)
        )
        drawText(
            stateLabel(window.state),
            at: CGPoint(x: tileRect.minX + 7, y: tileRect.maxY - 20),
            color: stateColor(window.state),
            font: .monospacedSystemFont(ofSize: 9, weight: .semibold)
        )
        if window.isFocused {
            let focus = "◆ FOCUS"
            let width = textSize(focus, font: .monospacedSystemFont(ofSize: 9, weight: .bold)).width
            drawText(
                focus,
                at: CGPoint(x: max(tileRect.minX + 7, tileRect.maxX - width - 7), y: tileRect.minY + 7),
                color: .controlAccentColor,
                font: .monospacedSystemFont(ofSize: 9, weight: .bold)
            )
        }
    }

    private func drawPreviews(_ previewRects: [WindowID: CGRect], baseline: [WindowID: CGRect]) {
        guard !previewRects.isEmpty else { return }
        let context = NSGraphicsContext.current?.cgContext
        for (windowID, rect) in previewRects.sorted(by: { $0.key.raw < $1.key.raw }) {
            let proposal = rect.insetBy(dx: 3, dy: 3)
            context?.saveGState()
            context?.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context?.setLineWidth(2)
            context?.setLineDash(phase: 0, lengths: [7, 4])
            context?.stroke(proposal)
            if let before = baseline[windowID], before.midX != proposal.midX || before.midY != proposal.midY {
                drawArrow(from: CGPoint(x: before.midX, y: before.midY), to: CGPoint(x: proposal.midX, y: proposal.midY))
            }
            context?.restoreGState()
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint) {
        let context = NSGraphicsContext.current?.cgContext
        context?.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor)
        context?.setLineWidth(1)
        context?.move(to: start)
        context?.addLine(to: end)
        context?.strokePath()
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 7
        for offset in [CGFloat.pi * 0.8, -CGFloat.pi * 0.8] {
            context?.move(to: end)
            context?.addLine(to: CGPoint(
                x: end.x + cos(angle + offset) * length,
                y: end.y + sin(angle + offset) * length
            ))
            context?.strokePath()
        }
    }

    private func drawEmptyCell(_ rect: CGRect) {
        let rect = rect.insetBy(dx: 3, dy: 3)
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        context?.setLineWidth(1)
        context?.setLineDash(phase: 0, lengths: [3, 4])
        context?.stroke(rect)
        context?.restoreGState()
        drawText(
            "EMPTY",
            at: CGPoint(x: rect.minX + 6, y: rect.minY + 6),
            color: .tertiaryLabelColor,
            font: .monospacedSystemFont(ofSize: 9, weight: .regular)
        )
    }

    private func drawCenteredMessage(_ message: String, in rect: CGRect) {
        let font = NSFont.systemFont(ofSize: 13)
        let size = textSize(message, font: font)
        drawText(
            message,
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            color: .secondaryLabelColor,
            font: font
        )
    }
}

private func fittedDisplayRect(for display: CGRect, in available: CGRect) -> CGRect {
    guard display.width > 0, display.height > 0, available.width > 0, available.height > 0 else { return .zero }
    let scale = min(available.width / display.width, available.height / display.height)
    let size = CGSize(width: display.width * scale, height: display.height * scale)
    return CGRect(
        x: available.midX - size.width / 2,
        y: available.midY - size.height / 2,
        width: size.width,
        height: size.height
    )
}

private func map(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
    guard source.width > 0, source.height > 0 else { return .zero }
    let xScale = target.width / source.width
    let yScale = target.height / source.height
    return CGRect(
        x: target.minX + (frame.minX - source.minX) * xScale,
        y: target.minY + (frame.minY - source.minY) * yScale,
        width: frame.width * xScale,
        height: frame.height * yScale
    )
}

private func treeCells(_ node: Node, frame: CGRect) -> [(Node, CGRect)] {
    switch node {
    case .void, .leaf:
        return [(node, frame)]
    case .split(let split):
        let total = split.cells.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [(node, frame)] }
        var offset: CGFloat = 0
        return split.cells.flatMap { cell in
            let fraction = cell.weight / total
            let childFrame: CGRect
            switch split.axis {
            case .horizontal:
                let width = frame.width * fraction
                childFrame = CGRect(x: frame.minX + offset, y: frame.minY, width: width, height: frame.height)
                offset += width
            case .vertical:
                let height = frame.height * fraction
                childFrame = CGRect(x: frame.minX, y: frame.minY + offset, width: frame.width, height: height)
                offset += height
            }
            return treeCells(cell.node, frame: childFrame)
        }
    }
}

private func borderColor(for window: WindowPresentation) -> NSColor {
    if window.isFocused { return .controlAccentColor }
    switch window.state {
    case .manualAdjustment: return .systemOrange
    case .temporarilyDetached: return .systemRed
    case .tiled, .floating: return .secondaryLabelColor
    }
}

private func stateColor(_ state: WindowManagementState) -> NSColor {
    switch state {
    case .tiled: return .secondaryLabelColor
    case .floating: return .systemTeal
    case .manualAdjustment: return .systemOrange
    case .temporarilyDetached: return .systemRed
    }
}

private func stateLabel(_ state: WindowManagementState) -> String {
    switch state {
    case .tiled: return "TILED"
    case .floating: return "FLOATING"
    case .manualAdjustment: return "ADJUSTING"
    case .temporarilyDetached: return "DETACHED"
    }
}

private func dashPattern(for state: WindowManagementState) -> [CGFloat] {
    switch state {
    case .tiled, .manualAdjustment: return []
    case .floating: return [2, 3]
    case .temporarilyDetached: return [7, 4]
    }
}

private func drawText(_ text: String, at point: CGPoint, color: NSColor, font: NSFont) {
    (text as NSString).draw(
        at: point,
        withAttributes: [
            .foregroundColor: color,
            .font: font
        ]
    )
}

private func textSize(_ text: String, font: NSFont) -> CGSize {
    (text as NSString).size(withAttributes: [.font: font])
}

private func truncated(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return String(value.prefix(max(1, limit - 1))) + "…"
}
