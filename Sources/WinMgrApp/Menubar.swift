import AppKit
import WinMgrCore

@MainActor
final class Menubar {
    private var statusItem: NSStatusItem?
    private let statusMenuItem = NSMenuItem(title: "Config: loaded", action: nil, keyEquivalent: "")
    private var reload: (() -> Void)?
    private var reset: (() -> Void)?
    private var quit: (() -> Void)?

    func start(reload: @escaping () -> Void, reset: @escaping () -> Void, quit: @escaping () -> Void) {
        guard statusItem == nil else { return }

        self.reload = reload
        self.reset = reset
        self.quit = quit

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "WM"

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Reload Config", action: #selector(reloadConfig)))
        menu.addItem(menuItem(title: "Reset Layout", action: #selector(resetLayout)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit WinMgr", action: #selector(quitApp)))
        item.menu = menu

        statusItem = item
    }

    func updateConfigStatus(_ status: ConfigStatus) {
        switch status {
        case .loaded:
            statusMenuItem.title = "Config: loaded"
        case .failed(let message):
            statusMenuItem.title = "Config: failed - \(message)"
        }
    }

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
