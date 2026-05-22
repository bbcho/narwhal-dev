import AppKit

@MainActor
final class HUDView: NSView {
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
