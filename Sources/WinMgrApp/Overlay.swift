import AppKit
import WinMgrCore

@MainActor
final class Overlay {
    private var borderConfig: BorderConfig
    private var hudConfig: HUDConfig
    private var borderWindow: NSWindow?
    private var borderView: BorderView?
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
private final class BorderView: NSView {
    init(border: BorderConfig) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        update(border: border)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(border: BorderConfig) {
        layer?.borderWidth = border.width
        layer?.borderColor = NSColor(hexRGB: border.colorHex)?.cgColor ?? NSColor.systemBlue.cgColor
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
