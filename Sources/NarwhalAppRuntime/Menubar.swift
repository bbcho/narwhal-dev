import AppKit
import NarwhalAppSupport
import NarwhalCore

struct MenubarActions {
    let openWorkbench: () -> Void
    let reloadConfig: () -> Void
    let retryStartup: () -> Void
    let openConfig: () -> Void
    let openAccessibilitySettings: () -> Void
    let revealLogs: () -> Void
    let toggleLaunchAtLogin: () -> Void
    let checkForUpdates: () -> Void
    let exportSupportBundle: () -> Void
    let copyDiagnostics: () -> Void
    let resetLayout: () -> Void
    let quit: () -> Void

    static let noOp = MenubarActions(
        openWorkbench: {},
        reloadConfig: {},
        retryStartup: {},
        openConfig: {},
        openAccessibilitySettings: {},
        revealLogs: {},
        toggleLaunchAtLogin: {},
        checkForUpdates: {},
        exportSupportBundle: {},
        copyDiagnostics: {},
        resetLayout: {},
        quit: {}
    )
}

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
    private var runtimeReadiness: RuntimeReadiness = .starting
    private var operatingStatus = MenubarOperatingStatus.empty
    private let statusMenuItem = NSMenuItem(title: "Config: loaded", action: nil, keyEquivalent: "")
    private let runtimeMenuItem = NSMenuItem(title: "Runtime: starting", action: nil, keyEquivalent: "")
    private let accessibilityMenuItem = NSMenuItem(title: "AX: unknown", action: nil, keyEquivalent: "")
    private let scopeMenuItem = NSMenuItem(title: "Scope: unknown", action: nil, keyEquivalent: "")
    private let focusMenuItem = NSMenuItem(title: "Focus: unknown", action: nil, keyEquivalent: "")
    private let lastCommandMenuItem = NSMenuItem(title: "Last: none", action: nil, keyEquivalent: "")
    private let retryMenuItem = NSMenuItem(title: "Retry Startup", action: #selector(retryStartup), keyEquivalent: "")
    private let loginItemMenuItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin),
        keyEquivalent: ""
    )
    private var loginItemStatus: LoginItemStatus = .unavailable
    private let updateMenuItem = NSMenuItem(
        title: "Check for Updates…",
        action: #selector(checkForUpdates),
        keyEquivalent: ""
    )
    private var updateStatus: UpdateMenuStatus = .idle
    private var actions: MenubarActions?
    private var maintenanceMenu: NSMenu?
    private var workspacePopover: WorkspaceOverviewPopoverController?
    private let lightIcon = NarwhalIconResources.statusItemIcon(variant: .light)
    private let darkIcon = NarwhalIconResources.statusItemIcon(variant: .dark)
    private var appearanceObservation: NSKeyValueObservation?

    func start(actions: MenubarActions) {
        guard statusItem == nil else { return }

        self.actions = actions

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton(item.button)

        let menu = NSMenu()
        [
            statusMenuItem,
            runtimeMenuItem,
            accessibilityMenuItem,
            scopeMenuItem,
            focusMenuItem,
            lastCommandMenuItem
        ].forEach { $0.isEnabled = false }
        menu.addItem(statusMenuItem)
        menu.addItem(runtimeMenuItem)
        menu.addItem(accessibilityMenuItem)
        menu.addItem(scopeMenuItem)
        menu.addItem(focusMenuItem)
        menu.addItem(lastCommandMenuItem)
        menu.addItem(.separator())
        retryMenuItem.target = self
        menu.addItem(retryMenuItem)
        menu.addItem(menuItem(title: "Reload Config", action: #selector(reloadConfig)))
        menu.addItem(menuItem(title: "Open Config", action: #selector(openConfig)))
        menu.addItem(menuItem(title: "Accessibility Settings", action: #selector(openAccessibilitySettings)))
        menu.addItem(menuItem(title: "Reveal Logs", action: #selector(revealLogs)))
        loginItemMenuItem.target = self
        menu.addItem(loginItemMenuItem)
        updateMenuItem.target = self
        menu.addItem(updateMenuItem)
        menu.addItem(menuItem(title: "Export Support Bundle…", action: #selector(exportSupportBundle)))
        menu.addItem(menuItem(title: "Copy Diagnostics", action: #selector(copyRuntimeDiagnostics)))
        menu.addItem(menuItem(title: "Reset Layout", action: #selector(resetLayout)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit Narwhal", action: #selector(quitApp)))
        maintenanceMenu = menu
        workspacePopover = WorkspaceOverviewPopoverController(
            openWorkbench: { [weak self] in
                self?.workspacePopover?.close()
                self?.actions?.openWorkbench()
            },
            showMaintenance: { [weak self] view in
                self?.showMaintenanceMenu(relativeTo: view)
            }
        )

        statusItem = item
        renderStatus()
    }

    func updateConfigStatus(_ status: ConfigStatus) {
        configStatus = status
        renderStatus()
    }

    func updateRuntimeReadiness(_ readiness: RuntimeReadiness) {
        runtimeReadiness = readiness
        renderStatus()
    }

    func updateOperatingStatus(_ status: MenubarOperatingStatus) {
        operatingStatus = status
        renderStatus()
    }

    func updateWorkspacePresentation(_ presentation: WorkbenchPresentation) {
        workspacePopover?.update(presentation)
    }

    func updateLoginItemStatus(_ status: LoginItemStatus) {
        loginItemStatus = status
        renderStatus()
    }

    func updateUpdateStatus(_ status: UpdateMenuStatus) {
        updateStatus = status
        renderStatus()
    }

    private func renderStatus() {
        switch configStatus {
        case .loaded:
            statusMenuItem.title = "Config: loaded"
        case .failed(let message):
            statusMenuItem.title = "Config: failed - \(truncate(message, maxLength: 72))"
        }
        runtimeMenuItem.title = "Runtime: \(runtimeReadiness.summary)"
        retryMenuItem.isEnabled = runtimeReadiness.canRetryStartup
        loginItemMenuItem.title = loginItemStatus.menuTitle
        loginItemMenuItem.state = loginItemStatus.isEnabled ? .on : .off
        loginItemMenuItem.isEnabled = loginItemStatus.canPerformAction
        updateMenuItem.title = updateStatus.title
        updateMenuItem.isEnabled = updateStatus.isEnabled
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

    func debugPerformMenuItem(titled title: String) -> Bool {
        guard let item = maintenanceMenu?.items.first(where: { $0.title == title }),
              let action = item.action
        else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    func debugMenuItem(titled title: String) -> (title: String, isEnabled: Bool)? {
        maintenanceMenu?.items.first(where: { $0.title == title }).map { ($0.title, $0.isEnabled) }
    }

    func debugMenuItemIsOn(titled title: String) -> Bool? {
        maintenanceMenu?.items.first(where: { $0.title == title }).map { $0.state == .on }
    }

    func debugMenuTitles() -> [String] {
        maintenanceMenu?.items.map(\.title) ?? []
    }
#endif

    func stop() {
        guard let statusItem else { return }
        workspacePopover?.close()
        workspacePopover = nil
        maintenanceMenu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        actions = nil
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
        button.target = self
        button.action = #selector(statusButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMaintenanceMenu(relativeTo: sender)
        } else {
            workspacePopover?.toggle(relativeTo: sender)
        }
    }

    private func showMaintenanceMenu(relativeTo view: NSView) {
        maintenanceMenu?.popUp(
            positioning: nil,
            at: CGPoint(x: 0, y: view.bounds.maxY + 4),
            in: view
        )
    }

    private func refreshButtonImage(_ button: NSStatusBarButton) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = isDark ? (darkIcon ?? lightIcon) : (lightIcon ?? darkIcon)
    }

    private var needsAttention: Bool {
        if case .failed = configStatus { return true }
        if runtimeReadiness != .operational { return true }
        if operatingStatus.accessibilityTrusted == false { return true }
        if let quality = operatingStatus.snapshotQuality,
           quality != .complete {
            return true
        }
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
        actions?.reloadConfig()
    }

    @objc
    private func retryStartup() {
        actions?.retryStartup()
    }

    @objc
    private func openConfig() {
        actions?.openConfig()
    }

    @objc
    private func openAccessibilitySettings() {
        actions?.openAccessibilitySettings()
    }

    @objc
    private func revealLogs() {
        actions?.revealLogs()
    }

    @objc
    private func toggleLaunchAtLogin() {
        actions?.toggleLaunchAtLogin()
    }

    @objc
    private func checkForUpdates() {
        actions?.checkForUpdates()
    }

    @objc
    private func exportSupportBundle() {
        actions?.exportSupportBundle()
    }

    @objc
    private func copyRuntimeDiagnostics() {
        actions?.copyDiagnostics()
    }

    @objc
    private func resetLayout() {
        actions?.resetLayout()
    }

    @objc
    private func quitApp() {
        actions?.quit()
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
    case .unavailable:
        return "unavailable"
    }
}

private func truncate(_ value: String, maxLength: Int) -> String {
    guard value.count > maxLength else { return value }
    return String(value.prefix(max(0, maxLength - 3))) + "..."
}
