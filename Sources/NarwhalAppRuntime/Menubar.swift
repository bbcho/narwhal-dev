import AppKit
import NarwhalCore

struct MenubarOperatingStatus: Equatable {
    var accessibilityTrusted: Bool?
    var activeSpace: SpaceID?
    var displayCount: Int?
    var windowCount: Int?
    var snapshotQuality: AXSnapshotQuality?
    var focusedWindowID: WindowID?
    var lastCommand: String?
    var paused: Bool

    static let empty = MenubarOperatingStatus(
        accessibilityTrusted: nil,
        activeSpace: nil,
        displayCount: nil,
        windowCount: nil,
        snapshotQuality: nil,
        focusedWindowID: nil,
        lastCommand: nil,
        paused: false
    )
}

@MainActor
final class Menubar {
    private var statusItem: NSStatusItem?
    private var configStatus: ConfigStatus = .loaded
    private var operatingStatus = MenubarOperatingStatus.empty
    private let statusMenuItem = NSMenuItem(title: "Config: loaded", action: nil, keyEquivalent: "")
    private let accessibilityMenuItem = NSMenuItem(title: "AX: unknown", action: nil, keyEquivalent: "")
    private let scopeMenuItem = NSMenuItem(title: "Scope: unknown", action: nil, keyEquivalent: "")
    private let focusMenuItem = NSMenuItem(title: "Focus: unknown", action: nil, keyEquivalent: "")
    private let lastCommandMenuItem = NSMenuItem(title: "Last: none", action: nil, keyEquivalent: "")
    private var reload: (() -> Void)?
    private var reset: (() -> Void)?
    private var quit: (() -> Void)?
    private let lightIcon = NarwhalIconResources.statusItemIcon(variant: .light)
    private let darkIcon = NarwhalIconResources.statusItemIcon(variant: .dark)
    private var appearanceObservation: NSKeyValueObservation?

    func start(reload: @escaping () -> Void, reset: @escaping () -> Void, quit: @escaping () -> Void) {
        guard statusItem == nil else { return }

        self.reload = reload
        self.reset = reset
        self.quit = quit

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton(item.button)

        let menu = NSMenu()
        [
            statusMenuItem,
            accessibilityMenuItem,
            scopeMenuItem,
            focusMenuItem,
            lastCommandMenuItem
        ].forEach { $0.isEnabled = false }
        menu.addItem(statusMenuItem)
        menu.addItem(accessibilityMenuItem)
        menu.addItem(scopeMenuItem)
        menu.addItem(focusMenuItem)
        menu.addItem(lastCommandMenuItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Reload Config", action: #selector(reloadConfig)))
        menu.addItem(menuItem(title: "Reset Layout", action: #selector(resetLayout)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit Narwhal", action: #selector(quitApp)))
        item.menu = menu

        statusItem = item
        renderStatus()
    }

    func updateConfigStatus(_ status: ConfigStatus) {
        configStatus = status
        renderStatus()
    }

    func updateOperatingStatus(_ status: MenubarOperatingStatus) {
        operatingStatus = status
        renderStatus()
    }

    private func renderStatus() {
        switch configStatus {
        case .loaded:
            statusMenuItem.title = "Config: loaded"
        case .failed(let message):
            statusMenuItem.title = "Config: failed - \(truncate(message, maxLength: 72))"
        }
        accessibilityMenuItem.title = "AX: \(accessibilityDescription)"
        scopeMenuItem.title = scopeDescription
        focusMenuItem.title = focusDescription
        lastCommandMenuItem.title = "Last: \(truncate(operatingStatus.lastCommand ?? "none", maxLength: 72))"
        statusItem?.button?.contentTintColor = operatingStatus.paused ? .systemOrange : (needsAttention ? .systemRed : nil)
    }

#if NARWHAL_ENABLE_VERIFIERS
    func debugStatusButtonSnapshot() -> MenubarStatusButtonSnapshot? {
        guard let button = statusItem?.button else { return nil }
        return MenubarStatusButtonSnapshot(
            hasImage: button.image != nil,
            imageName: button.image?.name(),
            isTemplate: button.image?.isTemplate ?? false,
            imageSize: button.image?.size ?? .zero,
            title: button.title,
            imagePosition: button.imagePosition
        )
    }
#endif

    func stop() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        reload = nil
        reset = nil
        quit = nil
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func configureStatusButton(_ button: NSStatusBarButton?) {
        guard let button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = "Narwhal"
        refreshButtonImage(button)
        // macOS doesn't reliably honor isTemplate on NSImage(contentsOf:)-loaded
        // images, so swap explicit light/dark PNGs based on effectiveAppearance.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem?.button else { return }
                self.refreshButtonImage(button)
            }
        }
    }

    private func refreshButtonImage(_ button: NSStatusBarButton) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = isDark ? (darkIcon ?? lightIcon) : (lightIcon ?? darkIcon)
    }

    private var needsAttention: Bool {
        if case .failed = configStatus { return true }
        if operatingStatus.accessibilityTrusted == false { return true }
        if case .permissionDenied = operatingStatus.snapshotQuality { return true }
        return false
    }

    private var accessibilityDescription: String {
        let trust: String
        switch operatingStatus.accessibilityTrusted {
        case .some(true):
            trust = "trusted"
        case .some(false):
            trust = "not trusted"
        case .none:
            trust = "unknown"
        }
        guard let quality = operatingStatus.snapshotQuality else { return trust }
        return "\(trust), snapshot \(snapshotQualityDescription(quality))"
    }

    private var scopeDescription: String {
        if operatingStatus.paused {
            return "Scope: paused"
        }
        let space = operatingStatus.activeSpace.map { "Space \($0.raw)" } ?? "Space unknown"
        let displays = operatingStatus.displayCount.map { "\($0) display\($0 == 1 ? "" : "s")" } ?? "displays unknown"
        let windows = operatingStatus.windowCount.map { "\($0) window\($0 == 1 ? "" : "s")" } ?? "windows unknown"
        return "Scope: \(space), \(displays), \(windows)"
    }

    private var focusDescription: String {
        "Focus: \(operatingStatus.focusedWindowID?.description ?? "unknown")"
    }

    @objc
    private func reloadConfig() {
        reload?()
    }

    @objc
    private func resetLayout() {
        reset?()
    }

    @objc
    private func quitApp() {
        quit?()
    }
}

#if NARWHAL_ENABLE_VERIFIERS
struct MenubarStatusButtonSnapshot {
    let hasImage: Bool
    let imageName: String?
    let isTemplate: Bool
    let imageSize: NSSize
    let title: String
    let imagePosition: NSControl.ImagePosition
}
#endif

enum NarwhalIconResources {
    enum Variant {
        case light  // black silhouette on light menubars
        case dark   // white silhouette on dark menubars

        var resourceName: String {
            switch self {
            case .light: return "NarwhalToolbarIcon"
            case .dark: return "NarwhalToolbarIconDark"
            }
        }
    }

    @MainActor
    static func statusItemIcon(variant: Variant) -> NSImage? {
        let name = variant.resourceName
        if let image = imageFromBundleResource(name) ?? imageFromRepositoryAsset(name) {
            image.setName(NSImage.Name(name))
            return image
        }
        return nil
    }

    @MainActor
    private static func imageFromBundleResource(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    @MainActor
    private static func imageFromRepositoryAsset(_ name: String) -> NSImage? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Packaging/Assets/\(name).png")
        return NSImage(contentsOf: url)
    }
}

private func snapshotQualityDescription(_ quality: AXSnapshotQuality) -> String {
    switch quality {
    case .complete:
        return "complete"
    case .partial(let errors):
        return "partial (\(errors.count) error\(errors.count == 1 ? "" : "s"))"
    case .permissionDenied:
        return "permission denied"
    }
}

private func truncate(_ value: String, maxLength: Int) -> String {
    guard value.count > maxLength else { return value }
    return String(value.prefix(max(0, maxLength - 3))) + "..."
}
