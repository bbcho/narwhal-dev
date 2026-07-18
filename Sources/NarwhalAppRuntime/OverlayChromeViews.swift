import AppKit

@MainActor
final class HUDView: NSView {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let horizontalPadding: CGFloat = 18
    static let height: CGFloat = 38
    private let messageLabel: NSTextField

    init(message: String, tone: OverlayTone) {
        messageLabel = NSTextField(labelWithString: message)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = tone.background.cgColor
        layer?.borderColor = tone.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        let label = messageLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Self.font
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(message)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

#if NARWHAL_ENABLE_VERIFIERS
    func debugSnapshot() -> HUDDebugSnapshot {
        layoutSubtreeIfNeeded()
        return HUDDebugSnapshot(
            message: messageLabel.stringValue,
            messageFrame: convert(messageLabel.bounds, from: messageLabel),
            accessibilityLabel: accessibilityLabel(),
            contrastRatio: Self.contrastRatio(foreground: .white, background: layerBackgroundColor)
        )
    }

    private var layerBackgroundColor: NSColor {
        guard let color = layer?.backgroundColor else { return .clear }
        return NSColor(cgColor: color) ?? .clear
    }
#endif

    private static func contrastRatio(foreground: NSColor, background: NSColor) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * linearComponent(Double(rgb.redComponent))
            + 0.7152 * linearComponent(Double(rgb.greenComponent))
            + 0.0722 * linearComponent(Double(rgb.blueComponent))
    }

    private static func linearComponent(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

#if NARWHAL_ENABLE_VERIFIERS
struct HUDDebugSnapshot {
    let message: String
    let messageFrame: CGRect
    let accessibilityLabel: String?
    let contrastRatio: Double
}
#endif

@MainActor
final class DragPreviewView: NSView {
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
            return NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
        case .success:
            return NSColor(srgbRed: 0.08, green: 0.33, blue: 0.18, alpha: 1)
        case .warning:
            return NSColor(srgbRed: 0.42, green: 0.23, blue: 0.00, alpha: 1)
        case .error:
            return NSColor(srgbRed: 0.50, green: 0.11, blue: 0.11, alpha: 1)
        }
    }

    var border: NSColor {
        switch self {
        case .info:
            return NSColor(srgbRed: 0.42, green: 0.45, blue: 0.50, alpha: 1)
        case .success:
            return NSColor(srgbRed: 0.29, green: 0.87, blue: 0.50, alpha: 1)
        case .warning:
            return NSColor(srgbRed: 0.98, green: 0.75, blue: 0.14, alpha: 1)
        case .error:
            return NSColor(srgbRed: 0.97, green: 0.44, blue: 0.44, alpha: 1)
        }
    }
}
