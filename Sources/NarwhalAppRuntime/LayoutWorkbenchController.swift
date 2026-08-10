import AppKit
import NarwhalAppSupport
import NarwhalCore

@MainActor
final class LayoutWorkbenchController: NSObject, NSWindowDelegate {
    typealias ApplyPlan = (CommandPlanResult, WorkbenchIntent) async -> Bool
    typealias ActivateManagedRules = ([ManagedWindowRule]) async throws -> Void
    typealias ManagedRulesSnapshot = () -> [ManagedWindowRule]

    private let worldActor: WorldActor
    private let snapshotQuality: () -> AXSnapshotQuality?
    private let applyPlan: ApplyPlan
    private let activateManagedRules: ActivateManagedRules
    private let managedRulesSnapshot: ManagedRulesSnapshot
    private let openAccessibilitySettings: () -> Void
    private let namedLayoutsStore: NamedLayoutsStore
    private let managedRulesStore: ManagedRulesStore

    private var window: NSWindow?
    private var presentation = WorkbenchPresentation(activeSpaceID: nil, workspaces: [])
    private var selectedWorkspaceKey: WorkspaceKey?
    private var selectedWindowID: WindowID?
    private var planned: (result: CommandPlanResult, intent: WorkbenchIntent)?
    private var namedLayouts: [NamedLayout] = []
    private var managedRules: [ManagedWindowRule] = []
    private var artifactWarnings: [ArtifactWarningSource: String] = [:]
    private var ruleEditor: ManagedRulesEditorController?

    private let railStack = NSStackView()
    private let canvas = LayoutCanvasView(frame: .zero)
    private let canvasTitle = NSTextField(labelWithString: "No workspace")
    private let inspectorStack = NSStackView()
    private let selectionTitle = NSTextField(labelWithString: "No window selected")
    private let selectionDetails = NSTextField(wrappingLabelWithString: "Select a window tile to inspect it.")
    private let changesLabel = NSTextField(wrappingLabelWithString: "No pending change")
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let accessibilityButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)
    private let scopeLabel = NSTextField(labelWithString: "No pending change")
    private let applyButton = NSButton(title: "Apply Change", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel Preview", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let redoButton = NSButton(title: "Redo", target: nil, action: nil)
    private let layoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let railContainer = NSView()
    private let railScrollView = NSScrollView()
    private let railDocumentView = WorkbenchScrollDocumentView()
    private let inspectorContainer = NSView()
    private let inspectorScrollView = NSScrollView()
    private let inspectorDocumentView = WorkbenchScrollDocumentView()

    init(
        worldActor: WorldActor,
        snapshotQuality: @escaping () -> AXSnapshotQuality?,
        applyPlan: @escaping ApplyPlan,
        activateManagedRules: @escaping ActivateManagedRules,
        managedRulesSnapshot: @escaping ManagedRulesSnapshot = { [] },
        openAccessibilitySettings: @escaping () -> Void,
        namedLayoutsStore: NamedLayoutsStore = NamedLayoutsStore(),
        managedRulesStore: ManagedRulesStore = ManagedRulesStore()
    ) {
        self.worldActor = worldActor
        self.snapshotQuality = snapshotQuality
        self.applyPlan = applyPlan
        self.activateManagedRules = activateManagedRules
        self.managedRulesSnapshot = managedRulesSnapshot
        self.openAccessibilitySettings = openAccessibilitySettings
        self.namedLayoutsStore = namedLayoutsStore
        self.managedRulesStore = managedRulesStore
        super.init()
    }

    func show() {
        loadArtifacts()
        if window == nil { window = makeWindow() }
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { await refreshPresentation() }
    }

    func close() {
        window?.close()
    }

    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        Task { await refreshPresentation() }
    }

    func updatePresentationIfVisible(_ presentation: WorkbenchPresentation) {
        guard window?.isVisible == true else { return }
        applyPresentation(presentation)
    }

    func windowWillClose(_ notification: Notification) {
        planned = nil
        canvas.preview = nil
    }

    func debugWindow() -> NSWindow? { window }

    func debugLayoutWidths() -> (rail: CGFloat, inspector: CGFloat, minimum: CGSize)? {
        guard let window else { return nil }
        window.contentView?.layoutSubtreeIfNeeded()
        return (railContainer.frame.width, inspectorContainer.frame.width, window.minSize)
    }

    func debugInspectorGeometry() -> (viewportHeight: CGFloat, contentHeight: CGFloat, hasVerticalScroller: Bool)? {
        guard window != nil else { return nil }
        inspectorContainer.layoutSubtreeIfNeeded()
        inspectorDocumentView.layoutSubtreeIfNeeded()
        return (
            inspectorScrollView.contentView.bounds.height,
            inspectorDocumentView.frame.height,
            inspectorScrollView.hasVerticalScroller
        )
    }

    func debugManagedRuleCount() -> Int {
        managedRules.count
    }

    func debugArtifactWarningText() -> String? {
        artifactWarningText
    }

    func debugRailHasVerticalScroller() -> Bool {
        railScrollView.hasVerticalScroller
    }

    func debugCanvasTitle() -> String {
        canvasTitle.stringValue
    }

    func debugRailToolTips() -> [String] {
        railStack.arrangedSubviews.compactMap { ($0 as? NSButton)?.toolTip }
    }

#if NARWHAL_ENABLE_VERIFIERS
    func debugPresent(
        _ presentation: WorkbenchPresentation,
        planned result: CommandPlanResult? = nil,
        intent: WorkbenchIntent? = nil,
        selectedWindowID: WindowID? = nil
    ) {
        applyPresentation(presentation)
        self.selectedWindowID = selectedWindowID
        canvas.selectedWindowID = selectedWindowID
        renderSelection()
        if let result, let intent {
            planned = (result, intent)
        } else {
            planned = nil
        }
        renderPreviewState()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func debugShowFailure(_ explanation: WorkbenchPlanExplanation) {
        showFailure(explanation)
        window?.contentView?.layoutSubtreeIfNeeded()
    }
#endif

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1020, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Narwhal Layout Workbench"
        window.minSize = CGSize(width: 860, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("NarwhalLayoutWorkbench")
        window.contentView = makeRootView()
        window.center()
        return window
    }

    private func makeRootView() -> NSView {
        let root = WorkbenchRootView()
        root.translatesAutoresizingMaskIntoConstraints = false

        configureRail()
        configureInspector()
        let center = makeCenterView()

        let separatorA = NSBox()
        separatorA.boxType = .separator
        separatorA.translatesAutoresizingMaskIntoConstraints = false
        let separatorB = NSBox()
        separatorB.boxType = .separator
        separatorB.translatesAutoresizingMaskIntoConstraints = false

        [railContainer, separatorA, center, separatorB, inspectorContainer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            railContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            railContainer.topAnchor.constraint(equalTo: root.topAnchor),
            railContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            railContainer.widthAnchor.constraint(equalToConstant: 172),
            separatorA.leadingAnchor.constraint(equalTo: railContainer.trailingAnchor),
            separatorA.topAnchor.constraint(equalTo: root.topAnchor),
            separatorA.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            center.leadingAnchor.constraint(equalTo: separatorA.trailingAnchor),
            center.topAnchor.constraint(equalTo: root.topAnchor),
            center.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separatorB.leadingAnchor.constraint(equalTo: center.trailingAnchor),
            separatorB.topAnchor.constraint(equalTo: root.topAnchor),
            separatorB.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspectorContainer.leadingAnchor.constraint(equalTo: separatorB.trailingAnchor),
            inspectorContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inspectorContainer.topAnchor.constraint(equalTo: root.topAnchor),
            inspectorContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspectorContainer.widthAnchor.constraint(equalToConstant: 264)
        ])
        return root
    }

    private func configureRail() {
        railStack.orientation = .vertical
        railStack.alignment = .leading
        railStack.spacing = 6
        railStack.translatesAutoresizingMaskIntoConstraints = false

        railScrollView.drawsBackground = false
        railScrollView.borderType = .noBorder
        railScrollView.hasHorizontalScroller = false
        railScrollView.hasVerticalScroller = true
        railScrollView.autohidesScrollers = true
        railScrollView.translatesAutoresizingMaskIntoConstraints = false
        railScrollView.contentView.drawsBackground = false
        railDocumentView.translatesAutoresizingMaskIntoConstraints = false
        railDocumentView.addSubview(railStack)
        railScrollView.documentView = railDocumentView
        let heading = sectionHeading("WORKSPACES")
        railContainer.addSubview(railScrollView)
        railStack.addArrangedSubview(heading)
        NSLayoutConstraint.activate([
            railScrollView.leadingAnchor.constraint(equalTo: railContainer.leadingAnchor),
            railScrollView.trailingAnchor.constraint(equalTo: railContainer.trailingAnchor),
            railScrollView.topAnchor.constraint(equalTo: railContainer.topAnchor),
            railScrollView.bottomAnchor.constraint(equalTo: railContainer.bottomAnchor),
            railDocumentView.widthAnchor.constraint(equalTo: railScrollView.contentView.widthAnchor),
            railDocumentView.heightAnchor.constraint(greaterThanOrEqualTo: railScrollView.contentView.heightAnchor),
            railStack.leadingAnchor.constraint(equalTo: railDocumentView.leadingAnchor, constant: 12),
            railStack.trailingAnchor.constraint(equalTo: railDocumentView.trailingAnchor, constant: -12),
            railStack.topAnchor.constraint(equalTo: railDocumentView.topAnchor, constant: 14),
            railStack.bottomAnchor.constraint(equalTo: railDocumentView.bottomAnchor, constant: -14)
        ])
    }

    private func configureInspector() {
        inspectorStack.orientation = .vertical
        inspectorStack.alignment = .leading
        inspectorStack.spacing = 8
        inspectorStack.translatesAutoresizingMaskIntoConstraints = false

        inspectorScrollView.drawsBackground = false
        inspectorScrollView.borderType = .noBorder
        inspectorScrollView.hasHorizontalScroller = false
        inspectorScrollView.hasVerticalScroller = true
        inspectorScrollView.autohidesScrollers = true
        inspectorScrollView.translatesAutoresizingMaskIntoConstraints = false
        inspectorDocumentView.translatesAutoresizingMaskIntoConstraints = false
        inspectorDocumentView.addSubview(inspectorStack)
        inspectorScrollView.documentView = inspectorDocumentView
        inspectorContainer.addSubview(inspectorScrollView)
        NSLayoutConstraint.activate([
            inspectorScrollView.leadingAnchor.constraint(equalTo: inspectorContainer.leadingAnchor),
            inspectorScrollView.trailingAnchor.constraint(equalTo: inspectorContainer.trailingAnchor),
            inspectorScrollView.topAnchor.constraint(equalTo: inspectorContainer.topAnchor),
            inspectorScrollView.bottomAnchor.constraint(equalTo: inspectorContainer.bottomAnchor),
            inspectorDocumentView.widthAnchor.constraint(equalTo: inspectorScrollView.contentView.widthAnchor),
            inspectorDocumentView.heightAnchor.constraint(greaterThanOrEqualTo: inspectorScrollView.contentView.heightAnchor),
            inspectorStack.leadingAnchor.constraint(equalTo: inspectorDocumentView.leadingAnchor, constant: 14),
            inspectorStack.trailingAnchor.constraint(equalTo: inspectorDocumentView.trailingAnchor, constant: -14),
            inspectorStack.topAnchor.constraint(equalTo: inspectorDocumentView.topAnchor, constant: 14),
            inspectorStack.bottomAnchor.constraint(equalTo: inspectorDocumentView.bottomAnchor, constant: -14)
        ])

        selectionTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        selectionTitle.lineBreakMode = .byTruncatingTail
        selectionTitle.toolTip = "Selected window; selection does not change macOS focus"
        selectionDetails.textColor = .secondaryLabelColor
        selectionDetails.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        changesLabel.textColor = .secondaryLabelColor
        explanationLabel.textColor = .systemRed
        explanationLabel.isHidden = true
        configureActionButton(
            accessibilityButton,
            action: #selector(openAccessibilityPreferences),
            help: "Open Privacy & Security settings so Narwhal can inspect and move application windows"
        )
        accessibilityButton.controlSize = .small
        accessibilityButton.isHidden = true

        inspectorStack.addArrangedSubview(sectionHeading("SELECTION"))
        inspectorStack.addArrangedSubview(selectionTitle)
        inspectorStack.addArrangedSubview(selectionDetails)
        inspectorStack.addArrangedSubview(separator())
        inspectorStack.addArrangedSubview(sectionHeading("PLACE / RESIZE"))
        inspectorStack.addArrangedSubview(directionRow(prefix: "Push", action: #selector(pushDirection(_:))))
        inspectorStack.addArrangedSubview(directionRow(prefix: "Resize", action: #selector(resizeDirection(_:))))
        inspectorStack.addArrangedSubview(actionRow([
            actionButton("Eject", #selector(previewEject), "Preview removing the selected window from the BSP tree"),
            actionButton("Balance", #selector(previewBalance), "Preview equal split weights in this workspace")
        ]))
        inspectorStack.addArrangedSubview(separator())
        inspectorStack.addArrangedSubview(sectionHeading("SPACE"))
        inspectorStack.addArrangedSubview(actionRow([
            actionButton("Shuffle", #selector(previewShuffle), "Preview a randomized reset layout"),
            actionButton("Cascade", #selector(previewCascade), "Preview a cascaded reset layout")
        ]))
        let reset = actionButton("Reset…", #selector(previewReset), "Preview clearing Narwhal's tree memory for this Space")
        inspectorStack.addArrangedSubview(reset)
        inspectorStack.addArrangedSubview(separator())
        inspectorStack.addArrangedSubview(sectionHeading("NAMED LAYOUT"))
        layoutPopup.translatesAutoresizingMaskIntoConstraints = false
        layoutPopup.setAccessibilityLabel("Named layout")
        layoutPopup.toolTip = "Choose a persisted semantic layout template"
        inspectorStack.addArrangedSubview(layoutPopup)
        inspectorStack.addArrangedSubview(actionRow([
            actionButton("Preview", #selector(previewNamedLayout), "Match and preview the selected named layout"),
            actionButton("Save…", #selector(saveNamedLayout), "Save this Space's current tree as a named layout")
        ]))
        inspectorStack.addArrangedSubview(actionRow([
            actionButton("Rename…", #selector(renameNamedLayout), "Rename the selected named layout"),
            actionButton("Delete…", #selector(deleteNamedLayout), "Delete the selected named layout after confirmation")
        ]))
        inspectorStack.addArrangedSubview(separator())
        inspectorStack.addArrangedSubview(sectionHeading("RULES"))
        inspectorStack.addArrangedSubview(actionButton(
            "Edit Managed Rules…",
            #selector(editManagedRules),
            "Edit ordered GUI-managed rules evaluated before Lua rules"
        ))
        inspectorStack.addArrangedSubview(separator())
        inspectorStack.addArrangedSubview(sectionHeading("PROPOSED CHANGE"))
        inspectorStack.addArrangedSubview(changesLabel)
        inspectorStack.addArrangedSubview(explanationLabel)
        inspectorStack.addArrangedSubview(accessibilityButton)
        inspectorStack.arrangedSubviews.forEach { view in
            view.widthAnchor.constraint(lessThanOrEqualTo: inspectorStack.widthAnchor).isActive = true
        }
    }

    private func makeCenterView() -> NSView {
        let center = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onSelectWindow = { [weak self] windowID in
            self?.selectedWindowID = windowID
            self?.renderSelection()
        }
        canvasTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        canvasTitle.translatesAutoresizingMaskIntoConstraints = false

        let actionRow = NSView()
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        scopeLabel.translatesAutoresizingMaskIntoConstraints = false
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.lineBreakMode = .byTruncatingTail

        configureActionButton(undoButton, action: #selector(previewUndo), help: "Preview the last committed change in this Space")
        configureActionButton(redoButton, action: #selector(previewRedo), help: "Preview the next committed change in this Space")
        configureActionButton(cancelButton, action: #selector(cancelPreview), help: "Discard the proposal without moving windows")
        configureActionButton(applyButton, action: #selector(applyPreview), help: "Apply the exact proposed frames to the named Space")
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        undoButton.keyEquivalent = "z"
        undoButton.keyEquivalentModifierMask = [.command]
        redoButton.keyEquivalent = "z"
        redoButton.keyEquivalentModifierMask = [.command, .shift]

        let actions = NSStackView(views: [undoButton, redoButton, cancelButton, applyButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        actionRow.addSubview(scopeLabel)
        actionRow.addSubview(actions)
        NSLayoutConstraint.activate([
            scopeLabel.leadingAnchor.constraint(equalTo: actionRow.leadingAnchor, constant: 12),
            scopeLabel.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            scopeLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: actionRow.trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: actionRow.centerYAnchor),
            actionRow.heightAnchor.constraint(equalToConstant: 48)
        ])

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        [canvasTitle, canvas, separator, actionRow].forEach(center.addSubview)
        NSLayoutConstraint.activate([
            canvasTitle.leadingAnchor.constraint(equalTo: center.leadingAnchor, constant: 14),
            canvasTitle.trailingAnchor.constraint(equalTo: center.trailingAnchor, constant: -14),
            canvasTitle.topAnchor.constraint(equalTo: center.topAnchor, constant: 14),
            canvas.topAnchor.constraint(equalTo: canvasTitle.bottomAnchor, constant: 8),
            canvas.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            separator.topAnchor.constraint(equalTo: canvas.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            actionRow.topAnchor.constraint(equalTo: separator.bottomAnchor),
            actionRow.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            actionRow.bottomAnchor.constraint(equalTo: center.bottomAnchor)
        ])
        renderPreviewState()
        return center
    }

    private func loadArtifacts() {
        do {
            switch try namedLayoutsStore.loadRecovering() {
            case .missing:
                namedLayouts = []
                artifactWarnings.removeValue(forKey: .namedLayouts)
            case .loaded(let layouts):
                namedLayouts = layouts
                artifactWarnings.removeValue(forKey: .namedLayouts)
            case .recoveredEmpty(let recovery):
                artifactWarnings[.namedLayouts] = recovery.error.description
            case .incompatible(let error):
                artifactWarnings[.namedLayouts] = error.description
            }
        } catch {
            artifactWarnings[.namedLayouts] = String(describing: error)
        }
        do {
            switch try managedRulesStore.loadRecovering() {
            case .missing:
                managedRules = []
                artifactWarnings.removeValue(forKey: .managedRules)
            case .loaded(let rules):
                managedRules = rules
                artifactWarnings.removeValue(forKey: .managedRules)
            case .recoveredEmpty(let recovery):
                managedRules = managedRulesSnapshot()
                artifactWarnings[.managedRules] = recovery.error.description
            case .incompatible(let error):
                managedRules = managedRulesSnapshot()
                artifactWarnings[.managedRules] = error.description
            }
        } catch {
            managedRules = managedRulesSnapshot()
            artifactWarnings[.managedRules] = String(describing: error)
        }
        renderLayoutPopup()
    }

    private func refreshPresentation() async {
        applyPresentation(await worldActor.workbenchPresentation(snapshotQuality: snapshotQuality()))
    }

    private func applyPresentation(_ presentation: WorkbenchPresentation) {
        self.presentation = presentation
        accessibilityButton.isHidden = !presentation.workspaces.contains {
            $0.health == .permissionRequired
        }
        if let selectedWorkspaceKey,
           !presentation.workspaces.contains(where: { $0.key == selectedWorkspaceKey }) {
            self.selectedWorkspaceKey = nil
        }
        if selectedWorkspaceKey == nil {
            selectedWorkspaceKey = presentation.workspaces.first(where: \.isActive)?.key
                ?? presentation.workspaces.first?.key
        }
        renderRail()
        renderWorkspace()
        Task { await renderHistoryAvailability() }
    }

    private func renderRail() {
        for view in railStack.arrangedSubviews.dropFirst() {
            railStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, workspace) in presentation.workspaces.enumerated() {
            let active = workspace.isActive ? "ACTIVE" : "MEMORY"
            let title = "D\(workspace.displaySlot) · S\(workspace.key.spaceID.raw)"
            let subtitle = "\(active)  \(workspace.health.label)\n\(workspace.tiledCount) tiled · \(workspace.floatingCount) floating"
            let button = NSButton(title: title + "\n" + subtitle, target: self, action: #selector(selectWorkspace(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.attributedTitle = NSAttributedString(
                string: title + "\n" + subtitle,
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: 11,
                        weight: selectedWorkspaceKey == workspace.key ? .semibold : .regular
                    ),
                    .foregroundColor: NSColor.labelColor
                ]
            )
            button.state = .off
            button.toolTip = workspaceToolTip(workspace)
            button.setAccessibilityLabel("Display \(workspace.displaySlot), Space \(workspace.key.spaceID.raw)")
            button.setAccessibilityValue("\(active), \(workspace.health.label), \(workspace.tiledCount) tiled, \(workspace.floatingCount) floating")
            railStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: railStack.widthAnchor).isActive = true
        }
    }

    private func workspaceToolTip(_ workspace: WorkspacePresentation) -> String {
        let summary = "Display \(workspace.displaySlot), Space \(workspace.key.spaceID.raw), \(workspace.health.label)"
        guard case .reconciliationRequired(let issue) = workspace.health else { return summary }
        return "\(summary): \(issue.operation): \(issue.reason)"
    }

    private func renderWorkspace() {
        guard let workspace = selectedWorkspace else {
            canvasTitle.stringValue = "No workspace available"
            canvas.workspace = nil
            selectedWindowID = nil
            renderSelection()
            return
        }
        canvasTitle.stringValue = "Display \(workspace.displaySlot) · Space \(workspace.key.spaceID.raw) · \(workspace.health.label)"
        canvas.workspace = workspace
        if let selectedWindowID,
           !workspace.windows.contains(where: { $0.id == selectedWindowID }) {
            self.selectedWindowID = nil
        }
        if selectedWindowID == nil { selectedWindowID = workspace.windows.first(where: \.isFocused)?.id ?? workspace.windows.first?.id }
        canvas.selectedWindowID = selectedWindowID
        renderSelection()
        if let artifactWarningText, planned == nil {
            explanationLabel.stringValue = artifactWarningText
            explanationLabel.isHidden = false
        }
    }

    private func renderSelection() {
        guard let window = selectedWindow else {
            selectionTitle.stringValue = "No window selected"
            selectionDetails.stringValue = "Select a window tile to inspect it.\nSelection does not change macOS focus."
            return
        }
        selectionTitle.stringValue = window.title
        selectionTitle.toolTip = window.title
        let focused = window.isFocused ? "YES" : "NO"
        selectionDetails.stringValue = [
            "STATE     \(stateText(window.state))",
            "FOCUS     \(focused)",
            "FRAME     \(frameText(window.frame))",
            "MINIMUM   \(minimumText(window.constraints))",
            "RULE      \(ruleSourceText(window.ruleSource))",
            "BUNDLE    \(window.bundleID.raw)",
            "ROLE      \(window.role)"
        ].joined(separator: "\n")
        selectionDetails.toolTip = selectionDetails.stringValue
    }

    private func renderPreviewState() {
        let hasPreview = planned != nil
        applyButton.isEnabled = hasPreview
        cancelButton.isEnabled = hasPreview
        if let planned {
            let preview = commandPreview(operation: planned.intent.operation, result: planned.result)
            canvas.preview = preview
            let count = preview.changes.count
            scopeLabel.stringValue = "Space \(preview.spaceID?.raw.description ?? "unknown") · \(count) affected"
            changesLabel.stringValue = preview.changes.isEmpty
                ? "No frame changes are required."
                : preview.changes.map { change in
                    let kinds = change.kinds.map(\.rawValue).joined(separator: ", ")
                    return "\(change.title): \(kinds)\n  \(frameText(change.before)) → \(frameText(change.after))"
                }.joined(separator: "\n")
            explanationLabel.isHidden = true
        } else {
            canvas.preview = nil
            scopeLabel.stringValue = "No pending change"
            changesLabel.stringValue = "No pending change"
            explanationLabel.isHidden = artifactWarningText == nil
            explanationLabel.stringValue = artifactWarningText ?? ""
        }
    }

    private func renderHistoryAvailability() async {
        guard let spaceID = selectedWorkspace?.key.spaceID else {
            undoButton.isEnabled = false
            redoButton.isEnabled = false
            return
        }
        let availability = await worldActor.layoutHistoryAvailability(spaceID: spaceID)
        guard selectedWorkspace?.key.spaceID == spaceID else { return }
        undoButton.isEnabled = availability.canUndo
        redoButton.isEnabled = availability.canRedo
        undoButton.toolTip = availability.undoLabel.map { "Preview undo: \($0)" } ?? "Nothing to undo in this Space"
        redoButton.toolTip = availability.redoLabel.map { "Preview redo: \($0)" } ?? "Nothing to redo in this Space"
    }

    private func renderLayoutPopup() {
        layoutPopup.removeAllItems()
        if namedLayouts.isEmpty {
            layoutPopup.addItem(withTitle: "No saved layouts")
            layoutPopup.isEnabled = false
        } else {
            layoutPopup.addItems(withTitles: namedLayouts.map { "\($0.name) · v\($0.revision)" })
            layoutPopup.isEnabled = true
        }
    }

    private var selectedWorkspace: WorkspacePresentation? {
        guard let selectedWorkspaceKey else { return nil }
        return presentation.workspaces.first { $0.key == selectedWorkspaceKey }
    }

    private var selectedWindow: WindowPresentation? {
        guard let selectedWindowID else { return nil }
        return selectedWorkspace?.windows.first { $0.id == selectedWindowID }
    }

    @objc private func selectWorkspace(_ sender: NSButton) {
        guard presentation.workspaces.indices.contains(sender.tag) else { return }
        selectedWorkspaceKey = presentation.workspaces[sender.tag].key
        selectedWindowID = nil
        planned = nil
        renderRail()
        renderWorkspace()
        renderPreviewState()
        Task { await renderHistoryAvailability() }
    }

    @objc private func pushDirection(_ sender: NSButton) {
        guard let windowID = selectedWindowID, let direction = direction(for: sender.tag) else { return }
        preview(.push(windowID: windowID, direction: direction))
    }

    @objc private func resizeDirection(_ sender: NSButton) {
        guard let windowID = selectedWindowID, let direction = direction(for: sender.tag) else { return }
        preview(.resize(windowID: windowID, direction: direction, delta: 0.05))
    }

    @objc private func previewEject() {
        guard let selectedWindowID else { return }
        preview(.eject(windowID: selectedWindowID))
    }

    @objc private func previewBalance() {
        guard let selectedWindowID else { return }
        preview(.balance(windowID: selectedWindowID))
    }

    @objc private func previewShuffle() { preview(.shuffle) }
    @objc private func previewCascade() { preview(.cascade) }
    @objc private func previewReset() { preview(.reset) }
    @objc private func previewUndo() { preview(.undo) }
    @objc private func previewRedo() { preview(.redo) }

    @objc private func previewNamedLayout() {
        guard layoutPopup.indexOfSelectedItem >= 0,
              namedLayouts.indices.contains(layoutPopup.indexOfSelectedItem),
              let spaceID = selectedWorkspace?.key.spaceID
        else { return }
        preview(.namedLayout(
            namedLayouts[layoutPopup.indexOfSelectedItem],
            spaceID: spaceID,
            allowPartial: false
        ))
    }

    private func preview(_ intent: WorkbenchIntent) {
        guard selectedWorkspace?.isActive == true else {
            showFailure(WorkbenchPlanExplanation(
                title: "Space is not active",
                reason: "Switch the display to this Space before previewing a window operation.",
                canRetryAsPartial: false
            ))
            return
        }
        Task {
            switch await planWorkbenchIntent(intent, with: worldActor) {
            case .success(let result):
                planned = (result, intent)
                renderPreviewState()
            case .failure(let failure):
                let windowTitles = presentation.workspaces
                    .flatMap(\.windows)
                    .reduce(into: [WindowID: String]()) { $0[$1.id] = $1.title }
                let explanation = workbenchExplanation(for: failure) { windowTitles[$0] }
                if explanation.canRetryAsPartial,
                   case .namedLayout(let layout, let spaceID, _) = intent {
                    offerPartialPreview(layout: layout, spaceID: spaceID, explanation: explanation)
                } else {
                    showFailure(explanation)
                }
            }
        }
    }

    private func offerPartialPreview(
        layout: NamedLayout,
        spaceID: SpaceID,
        explanation: WorkbenchPlanExplanation
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = explanation.title
        alert.informativeText = explanation.reason
        alert.addButton(withTitle: "Preview Matching Windows")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.preview(.namedLayout(layout, spaceID: spaceID, allowPartial: true))
        }
    }

    private func showFailure(_ explanation: WorkbenchPlanExplanation) {
        planned = nil
        canvas.preview = nil
        scopeLabel.stringValue = "Change blocked"
        changesLabel.stringValue = explanation.title
        explanationLabel.stringValue = explanation.reason
        explanationLabel.isHidden = false
        applyButton.isEnabled = false
        cancelButton.isEnabled = true
        if explanation.title == "Workspace is unavailable" || explanation.title == "Space is not active" {
            explanationLabel.toolTip = "Refresh the workspace or switch to the active Space"
        }
    }

    @objc private func cancelPreview() {
        planned = nil
        renderPreviewState()
    }

    @objc private func applyPreview() {
        guard let planned else { return }
        if planned.intent.requiresDestructiveConfirmation {
            confirmResetAndApply(planned)
        } else {
            performApply(planned)
        }
    }

    private func confirmResetAndApply(_ planned: (result: CommandPlanResult, intent: WorkbenchIntent)) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset this Space's layout memory?"
        alert.informativeText = "The current BSP tree will be cleared. The successful change will remain available through Undo."
        alert.addButton(withTitle: "Reset Space")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performApply(planned)
        }
    }

    private func performApply(_ planned: (result: CommandPlanResult, intent: WorkbenchIntent)) {
        setEditingEnabled(false)
        Task {
            guard await worldActor.isCurrent(planned.result) else {
                setEditingEnabled(true)
                self.planned = nil
                await refreshPresentation()
                showFailure(WorkbenchPlanExplanation(
                    title: "Preview is out of date",
                    reason: "The workspace changed after this proposal was created. Review the refreshed layout and preview the operation again.",
                    canRetryAsPartial: false
                ))
                return
            }
            let succeeded = await applyPlan(planned.result, planned.intent)
            setEditingEnabled(true)
            if succeeded {
                self.planned = nil
                await refreshPresentation()
                renderPreviewState()
            } else {
                explanationLabel.stringValue = "The application did not accept every requested frame. The proposal was not committed."
                explanationLabel.isHidden = false
            }
        }
    }

    private func setEditingEnabled(_ enabled: Bool) {
        inspectorStack.arrangedSubviews.forEach { setControls(in: $0, enabled: enabled) }
        applyButton.isEnabled = enabled && planned != nil
        cancelButton.isEnabled = enabled && planned != nil
    }

    @objc private func saveNamedLayout() {
        guard let spaceID = selectedWorkspace?.key.spaceID else { return }
        promptForName(title: "Save Named Layout", initial: "") { [weak self] name, useTitleHint in
            guard let self else { return }
            Task {
                let existing = self.namedLayouts.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
                let id = existing?.id ?? NamedLayoutID(rawValue: UUID().uuidString.lowercased())
                let revision = (existing?.revision ?? 0) + 1
                let hints: Set<WindowID> = useTitleHint ? Set(self.selectedWindowID.map { [$0] } ?? []) : []
                switch await self.worldActor.captureNamedLayout(
                    id: id,
                    name: name,
                    revision: revision,
                    spaceID: spaceID,
                    includeTitleHints: hints
                ) {
                case .failure:
                    self.showArtifactError("The current Space does not contain a valid layout tree to save.")
                case .success(let layout):
                    let updated = self.namedLayouts.filter { $0.id != id } + [layout]
                    self.persistNamedLayouts(updated.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }))
                }
            }
        }
    }

    @objc private func renameNamedLayout() {
        guard let layout = selectedNamedLayout else { return }
        promptForName(title: "Rename Named Layout", initial: layout.name, showsTitleHint: false) { [weak self] name, _ in
            guard let self else { return }
            let replacement = NamedLayout(
                id: layout.id,
                name: name,
                revision: layout.revision + 1,
                displays: layout.displays
            )
            self.persistNamedLayouts(self.namedLayouts.map { $0.id == layout.id ? replacement : $0 })
        }
    }

    @objc private func deleteNamedLayout() {
        guard let layout = selectedNamedLayout, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(layout.name)”?"
        alert.informativeText = "This removes the saved layout artifact. It does not move any windows."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.persistNamedLayouts(self.namedLayouts.filter { $0.id != layout.id })
        }
    }

    private var selectedNamedLayout: NamedLayout? {
        let index = layoutPopup.indexOfSelectedItem
        return namedLayouts.indices.contains(index) ? namedLayouts[index] : nil
    }

    private func persistNamedLayouts(_ layouts: [NamedLayout]) {
        do {
            try namedLayoutsStore.save(layouts)
            namedLayouts = layouts
            artifactWarnings.removeValue(forKey: .namedLayouts)
            artifactWarnings.removeValue(forKey: .operation)
            renderLayoutPopup()
        } catch {
            showArtifactError("Named layouts were not saved: \(error)")
        }
    }

    @objc private func editManagedRules() {
        guard let window else { return }
        let editor = ManagedRulesEditorController(
            rules: managedRules,
            matchCounts: managedRuleMatchCounts()
        ) { [weak self] rules in
            guard let self else { return }
            try self.managedRulesStore.save(rules)
            try await self.activateManagedRules(rules)
            self.managedRules = rules
            self.artifactWarnings.removeValue(forKey: .managedRules)
            self.artifactWarnings.removeValue(forKey: .operation)
            await self.refreshPresentation()
        }
        ruleEditor = editor
        editor.beginSheet(for: window)
    }

    private func managedRuleMatchCounts() -> [ManagedRuleID: Int] {
        presentation.workspaces
            .flatMap(\.windows)
            .reduce(into: [:]) { counts, window in
                guard case .managed(let id, _) = window.ruleSource else { return }
                counts[id, default: 0] += 1
            }
    }

    @objc private func openAccessibilityPreferences() {
        openAccessibilitySettings()
    }

    private func promptForName(
        title: String,
        initial: String,
        showsTitleHint: Bool = true,
        completion: @escaping (String, Bool) -> Void
    ) {
        guard let window else { return }
        let field = NSTextField(string: initial)
        field.placeholderString = "Layout name"
        field.setAccessibilityLabel("Layout name")
        let titleHint = NSButton(checkboxWithTitle: "Use selected window title as an exact match hint", target: nil, action: nil)
        titleHint.isHidden = !showsTitleHint
        titleHint.toolTip = "Window titles can contain document names; this is off unless explicitly selected"
        let stack = NSStackView(views: [field, titleHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = CGRect(x: 0, y: 0, width: 360, height: showsTitleHint ? 52 : 24)
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Named layouts save bundle IDs, roles, tree structure, and split weights—not live window IDs or PIDs."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            completion(name, titleHint.state == .on)
        }
    }

    private func showArtifactError(_ message: String) {
        artifactWarnings[.operation] = message
        explanationLabel.stringValue = message
        explanationLabel.isHidden = false
    }

    private var artifactWarningText: String? {
        let messages = ArtifactWarningSource.allCases.compactMap { artifactWarnings[$0] }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func directionRow(prefix: String, action: Selector) -> NSView {
        let directions: [(String, Direction)] = [("←", .left), ("↑", .up), ("↓", .down), ("→", .right)]
        let buttons = directions.enumerated().map { tag, entry -> NSButton in
            let (title, direction) = entry
            let button = actionButton(title, action, "\(prefix) \(direction.rawValue)")
            button.tag = tag
            button.setAccessibilityLabel("\(prefix) \(direction.rawValue)")
            return button
        }
        return actionRow(buttons)
    }

    private func actionRow(_ buttons: [NSButton]) -> NSView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        return stack
    }

    private func actionButton(_ title: String, _ action: Selector, _ help: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = help
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(help)
        return button
    }

    private func configureActionButton(_ button: NSButton, action: Selector, help: String) {
        button.target = self
        button.action = action
        button.toolTip = help
        button.setAccessibilityLabel(button.title)
        button.setAccessibilityHelp(help)
    }

    private func sectionHeading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

private enum ArtifactWarningSource: CaseIterable {
    case namedLayouts
    case managedRules
    case operation
}

private final class WorkbenchRootView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

private final class WorkbenchScrollDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private func direction(for tag: Int) -> Direction? {
    switch tag {
    case 0: return .left
    case 1: return .up
    case 2: return .down
    case 3: return .right
    default: return nil
    }
}

private func setControls(in view: NSView, enabled: Bool) {
    if let control = view as? NSControl { control.isEnabled = enabled }
    view.subviews.forEach { setControls(in: $0, enabled: enabled) }
}

private func stateText(_ state: WindowManagementState) -> String {
    switch state {
    case .tiled: return "TILED"
    case .floating: return "FLOATING"
    case .manualAdjustment: return "ADJUSTING"
    case .temporarilyDetached(let reason): return "DETACHED (\(reason.rawValue))"
    }
}

private func frameText(_ frame: CGRect?) -> String {
    guard let frame else { return "—" }
    return String(format: "x%.0f y%.0f  %.0f×%.0f", frame.minX, frame.minY, frame.width, frame.height)
}

private func minimumText(_ constraints: WindowConstraints) -> String {
    guard constraints.minWidth != nil || constraints.minHeight != nil else { return "none" }
    return "\(constraints.minWidth.map { String(format: "%.0f", $0) } ?? "—") × \(constraints.minHeight.map { String(format: "%.0f", $0) } ?? "—")"
}

private func ruleSourceText(_ source: WindowRuleSource) -> String {
    switch source {
    case .managed(_, let name): return "MANAGED · \(name)"
    case .lua(let index): return "LUA · #\(index + 1)"
    case .defaultBehavior: return "DEFAULT"
    }
}
