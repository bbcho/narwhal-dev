import AppKit
import QuartzCore
import NarwhalCore

#if NARWHAL_ENABLE_VERIFIERS
@MainActor
struct FocusBorderDebugGeometrySnapshot {
    let strokeRect: CGRect
    let requestedCornerRadius: Double
    let renderedCornerRadius: Double
    let pathBoundingBox: CGRect
}
#endif

@MainActor
final class BorderView: NSView {
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

#if NARWHAL_ENABLE_VERIFIERS
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
#endif

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
