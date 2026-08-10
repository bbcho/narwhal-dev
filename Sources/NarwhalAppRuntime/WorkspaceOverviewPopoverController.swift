import AppKit
import NarwhalAppSupport
import NarwhalCore

@MainActor
final class WorkspaceOverviewPopoverController {
    private let popover = NSPopover()
    private let contentController: WorkspaceOverviewViewController

    init(openWorkbench: @escaping () -> Void, showMaintenance: @escaping (NSView) -> Void) {
        contentController = WorkspaceOverviewViewController(
            openWorkbench: openWorkbench,
            showMaintenance: showMaintenance
        )
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = CGSize(width: 360, height: 220)
        popover.contentViewController = contentController
    }

    func update(_ presentation: WorkbenchPresentation) {
        contentController.update(presentation)
        popover.contentSize = contentController.preferredContentSize
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func close() {
        popover.performClose(nil)
    }

    func debugRowTexts() -> [String] {
        contentController.debugRowTexts()
    }
}

@MainActor
private final class WorkspaceOverviewViewController: NSViewController {
    private let openWorkbench: () -> Void
    private let showMaintenance: (NSView) -> Void
    private let rows = NSStackView()
    private var rowTexts: [String] = []

    init(openWorkbench: @escaping () -> Void, showMaintenance: @escaping (NSView) -> Void) {
        self.openWorkbench = openWorkbench
        self.showMaintenance = showMaintenance
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Narwhal Workspaces")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let open = NSButton(title: "Open Layout Workbench…", target: self, action: #selector(openWorkbenchAction))
        open.bezelStyle = .rounded
        open.setAccessibilityHelp("Open the full geometry, preview, rules, and named-layout editor")
        open.translatesAutoresizingMaskIntoConstraints = false
        let gearImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Maintenance") ?? NSImage()
        let gear = NSButton(image: gearImage, target: self, action: #selector(showMaintenanceAction(_:)))
        gear.bezelStyle = .texturedRounded
        gear.toolTip = "Maintenance and diagnostics"
        gear.setAccessibilityLabel("Maintenance and diagnostics")
        gear.translatesAutoresizingMaskIntoConstraints = false

        [title, rows, separator, open, gear].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            rows.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            rows.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 8),
            open.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            open.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
            open.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            gear.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            gear.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            gear.leadingAnchor.constraint(greaterThanOrEqualTo: open.trailingAnchor, constant: 10)
        ])
        view = root
        preferredContentSize = CGSize(width: 360, height: 164)
    }

    func update(_ presentation: WorkbenchPresentation) {
        loadViewIfNeeded()
        rows.arrangedSubviews.forEach { view in
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let active = presentation.workspaces.filter(\.isActive)
        let visible = active.isEmpty ? presentation.workspaces : active
        rowTexts = visible.map(rowText)
        if visible.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "No display or Space state is available yet.")
            empty.textColor = .secondaryLabelColor
            empty.setAccessibilityLabel("No workspace state available")
            addFullWidthRow(paddedRow(empty))
        } else {
            for (index, workspace) in visible.enumerated() {
                if index > 0 { addFullWidthRow(rowSeparator()) }
                addFullWidthRow(workspaceRow(workspace))
            }
        }
        let rowHeight = visible.isEmpty ? 48 : visible.count * 58 + max(0, visible.count - 1)
        preferredContentSize = CGSize(width: 360, height: CGFloat(116 + rowHeight))
    }

    func debugRowTexts() -> [String] { rowTexts }

    private func workspaceRow(_ workspace: WorkspacePresentation) -> NSView {
        let focused = workspace.windows.first(where: \.isFocused)
        let focus = focused.map { $0.bundleID.raw.isEmpty ? $0.title : $0.bundleID.raw } ?? "No focused window"
        let title = NSTextField(labelWithString: "Display \(workspace.displaySlot) · Space \(workspace.key.spaceID.raw)")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let status = NSTextField(labelWithString: "\(healthSymbol(workspace.health)) \(workspace.health.label)   \(workspace.tiledCount) tiled · \(workspace.floatingCount) floating")
        status.font = .systemFont(ofSize: 11)
        status.textColor = healthColor(workspace.health)
        status.toolTip = reconciliationReason(workspace.health)
        let focusedLabel = NSTextField(labelWithString: "Focus: \(focus)")
        focusedLabel.font = .systemFont(ofSize: 10)
        focusedLabel.textColor = .secondaryLabelColor
        focusedLabel.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [title, status, focusedLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel(rowText(workspace))
        return paddedRow(stack)
    }

    private func paddedRow(_ content: NSView) -> NSView {
        let row = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4)
        ])
        return row
    }

    private func rowSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func addFullWidthRow(_ row: NSView) {
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    private func rowText(_ workspace: WorkspacePresentation) -> String {
        let focus = workspace.windows.first(where: \.isFocused)?.bundleID.raw ?? "none"
        return "Display \(workspace.displaySlot), Space \(workspace.key.spaceID.raw), \(workspace.health.label), \(workspace.tiledCount) tiled, \(workspace.floatingCount) floating, focus \(focus)"
    }

    @objc private func openWorkbenchAction() {
        openWorkbench()
    }

    @objc private func showMaintenanceAction(_ sender: NSButton) {
        showMaintenance(sender)
    }
}

private func healthSymbol(_ health: WorkspaceHealth) -> String {
    switch health {
    case .ready: return "●"
    case .partialInventory: return "▲"
    case .permissionRequired: return "▣"
    case .unavailable: return "—"
    case .constraintConflict: return "!"
    case .reconciliationRequired: return "!"
    }
}

private func healthColor(_ health: WorkspaceHealth) -> NSColor {
    switch health {
    case .ready: return .secondaryLabelColor
    case .partialInventory, .constraintConflict: return .systemOrange
    case .reconciliationRequired: return .systemRed
    case .permissionRequired, .unavailable: return .systemRed
    }
}

private func reconciliationReason(_ health: WorkspaceHealth) -> String? {
    guard case .reconciliationRequired(let issue) = health else { return nil }
    return "\(issue.operation): \(issue.reason)"
}
