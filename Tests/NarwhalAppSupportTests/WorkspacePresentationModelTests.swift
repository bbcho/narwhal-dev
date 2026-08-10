import CoreGraphics
import NarwhalAppSupport
import NarwhalCore
import Testing

@Suite("Workspace presentation")
struct WorkspacePresentationModelTests {
    private let displayID = DisplayID(raw: 1)
    private let spaceID = SpaceID(raw: 10)

    @Test("Window states distinguish layout membership from transient interaction")
    func windowStatesAreExplicit() {
        let tiled = WindowID(raw: 1)
        let floating = WindowID(raw: 2)
        let detached = WindowID(raw: 3)
        let display = DisplaySpaceState(
            displayID: displayID,
            tree: .leaf(tiled),
            floating: [floating]
        )

        #expect(windowManagementState(for: tiled, displayState: display, interaction: nil) == .tiled)
        #expect(windowManagementState(for: floating, displayState: display, interaction: nil) == .floating)
        #expect(windowManagementState(for: detached, displayState: display, interaction: nil) == .temporarilyDetached(.reconciliationPending))
        #expect(windowManagementState(for: tiled, displayState: display, interaction: .manualAdjustment) == .manualAdjustment)
        #expect(windowManagementState(
            for: tiled,
            displayState: display,
            interaction: .temporarilyDetached(.applicationConstraint)
        ) == .temporarilyDetached(.applicationConstraint))
    }

    @Test("Workbench snapshot separates focus and interaction state")
    func workbenchSnapshot() throws {
        let tiled = metadata(1, title: "Editor")
        let floating = metadata(2, title: "Palette", x: 500)
        let tree = try split(.horizontal, [
            try cell(1, .leaf(tiled.id)),
            try cell(1, .void)
        ])
        let world = world(
            windows: [tiled, floating],
            tree: tree,
            floating: [floating.id],
            focused: tiled.id
        )
        let runtime = worldRuntimeBySettingInteraction(
            .manualAdjustment,
            for: tiled.id,
            in: .empty
        )

        let snapshot = workbenchPresentation(in: world, runtime: runtime, snapshotQuality: .complete)
        let workspace = try #require(snapshot.workspaces.first)

        #expect(workspace.health == .ready)
        #expect(workspace.displaySlot == 0)
        #expect(workspace.windows.count == 2)
        #expect(workspace.windows.first { $0.id == tiled.id }?.state == .manualAdjustment)
        #expect(workspace.windows.first { $0.id == tiled.id }?.isFocused == true)
        #expect(workspace.windows.first { $0.id == tiled.id }?.ruleSource == .defaultBehavior)
        #expect(workspace.windows.first { $0.id == floating.id }?.state == .floating)
        #expect(workspace.isActive)
    }

    @Test("Permission, partial inventory, and layout conflict remain distinct")
    func healthStatesAreDistinct() throws {
        let window = metadata(1, title: "Large")
        let constrained = world(
            windows: [window],
            tree: .leaf(window.id),
            constraints: [window.id: WindowConstraints(minWidth: 2_000)]
        )

        #expect(workbenchPresentation(
            in: constrained,
            runtime: .empty,
            snapshotQuality: .permissionDenied("missing")
        ).workspaces.first?.health == .permissionRequired)
        #expect(workbenchPresentation(
            in: constrained,
            runtime: .empty,
            snapshotQuality: .partial([AXWindowReadError(windowID: nil, pid: nil, message: "failed")])
        ).workspaces.first?.health == .partialInventory(errorCount: 1))

        guard case .constraintConflict = workbenchPresentation(
            in: constrained,
            runtime: .empty,
            snapshotQuality: .complete
        ).workspaces.first?.health else {
            Issue.record("Expected a constraint conflict")
            return
        }
    }

    @Test("Reconciliation health is scoped to one workspace and names the recovery state")
    func reconciliationHealthIsWorkspaceScoped() {
        let secondDisplay = DisplayID(raw: 2)
        let secondSpace = SpaceID(raw: 20)
        let key = WorkspaceKey(displayID: displayID, spaceID: spaceID)
        let issue = WorkspaceReconciliationIssue(
            operation: "Resize Right",
            windowIDs: [WindowID(raw: 1)],
            reason: "WindowServer frame remained stale"
        )
        let base = world(windows: [], tree: .void)
        let secondInfo = DisplayInfo(
            id: secondDisplay,
            slot: 1,
            fingerprint: nil,
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        )
        let combined = World(
            displays: base.displays.merging([secondDisplay: secondInfo]) { _, replacement in replacement },
            activeSpace: spaceID,
            activeSpaceByDisplay: [displayID: spaceID, secondDisplay: secondSpace],
            spaces: base.spaces.merging([
                secondSpace: SpaceState(
                    id: secondSpace,
                    displays: [
                        secondDisplay: DisplaySpaceState(displayID: secondDisplay, tree: .void, floating: [])
                    ],
                    focused: nil
                )
            ]) { _, replacement in replacement },
            windows: [:],
            windowDisplay: [:],
            windowSpace: [:],
            observedVisibleWindows: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let runtime = worldRuntimeByRecordingReconciliationIssue(issue, for: key, in: .empty)

        let presentation = workbenchPresentation(
            in: combined,
            runtime: runtime,
            snapshotQuality: .complete
        )

        #expect(presentation.workspaces.first { $0.key == key }?.health == .reconciliationRequired(issue))
        #expect(presentation.workspaces.first { $0.key == key }?.health.label == "Reconciliation required")
        #expect(presentation.workspaces.first {
            $0.key == WorkspaceKey(displayID: secondDisplay, spaceID: secondSpace)
        }?.health == .ready)
    }

    @Test("Preview lists every frame and management-state change")
    func previewListsAffectedWindows() throws {
        let first = metadata(1, title: "One", width: 1_000)
        let second = metadata(2, title: "Two", x: 1_000, width: 300)
        let before = world(windows: [first, second], tree: .leaf(first.id), floating: [second.id])
        let after = try apply(.push(second.id, .right), to: before).get()
        let plan = try commandPlan(
            from: before,
            to: after,
            focusedWindowID: second.id,
            undoWorld: before,
            generation: LayoutGeneration(raw: 1)
        ).get()

        let preview = commandPreview(operation: .push(.right), result: plan)

        #expect(preview.operation == .push(.right))
        #expect(preview.spaceID == spaceID)
        #expect(Set(preview.changes.map(\.windowID)) == [first.id, second.id])
        #expect(preview.changes.first { $0.windowID == second.id }?.kinds.contains(.managementState) == true)
    }

    @Test("Every rejection maps to concrete operator language and recovery")
    func rejectionExplanations() {
        let conflict = UnsatisfiableLayout(
            displayID: displayID,
            axis: .horizontal,
            available: 900,
            required: 1_200,
            windows: [WindowID(raw: 1)]
        )
        let cases: [CommandError] = [
            .windowNotFound(WindowID(raw: 1)),
            .windowIsFloating(WindowID(raw: 1)),
            .windowIsTiled(WindowID(raw: 1)),
            .windowNotResizable(WindowID(raw: 1)),
            .activeSpaceUnavailable,
            .spaceNotFound(spaceID),
            .displayNotFound(displayID),
            .displayUnknownForWindow(WindowID(raw: 1)),
            .noFocusedWindow,
            .noNeighbor(.left),
            .invalidResizeDelta,
            .resizeWouldCollapseSplit(WindowID(raw: 1), .left),
            .layoutUnsatisfiable(conflict),
            .zoneNotFound(ZoneID(raw: "gone")),
            .ruleInvalid("bad matcher"),
            .configInvalid("bad config")
        ]

        for error in cases {
            let explanation = commandExplanation(for: error)
            #expect(explanation.code == error.code)
            #expect(!explanation.title.isEmpty)
            #expect(!explanation.reason.isEmpty)
        }
        #expect(commandExplanation(for: .layoutUnsatisfiable(conflict)).reason.contains("1200 pt"))
    }

    private func metadata(
        _ raw: UInt32,
        title: String,
        x: CGFloat = 0,
        width: CGFloat = 500
    ) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: raw),
            bundleID: BundleID(raw: "com.example.\(raw)"),
            title: title,
            role: "AXWindow",
            pid: ProcessID(Int32(raw)),
            frame: CGRect(x: x, y: 0, width: width, height: 800),
            isResizable: true,
            isMinimized: false
        )
    }

    private func world(
        windows: [WindowMetadata],
        tree: Node,
        floating: [WindowID] = [],
        focused: WindowID? = nil,
        constraints: [WindowID: WindowConstraints] = [:]
    ) -> World {
        let display = DisplayInfo(
            id: displayID,
            slot: 0,
            fingerprint: nil,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        return World(
            displays: [displayID: display],
            activeSpace: spaceID,
            spaces: [
                spaceID: SpaceState(
                    id: spaceID,
                    displays: [displayID: DisplaySpaceState(displayID: displayID, tree: tree, floating: floating)],
                    focused: focused
                )
            ],
            windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }),
            windowDisplay: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, displayID) }),
            windowConstraints: constraints,
            pendingRules: [:],
            config: .default
        )
    }

    private func cell(_ weight: Double, _ node: Node) throws -> Cell {
        try Cell.create(weight: weight, node: node).get()
    }

    private func split(_ axis: Axis, _ cells: [Cell]) throws -> Node {
        .split(try Split.create(axis: axis, cells: cells).get())
    }
}
