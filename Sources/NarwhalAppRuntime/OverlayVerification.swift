import AppKit
import Darwin
import NarwhalAppSupport
import NarwhalCore

#if NARWHAL_ENABLE_VERIFIERS
@MainActor
enum CommandOverlayVerification {
    static func verifyDefaultTwoColumnLayout() -> (passed: Bool, message: String) {
        let sections = commandOverlaySections(
            for: Config.default.keymap,
            dragModifier: Config.default.dragModifier,
            zones: Config.default.zones
        )
        let regularAvailableSize = CGSize(width: 2200, height: 760)
        let metrics = CommandOverlayMetrics.fitting(sections: sections, availableSize: regularAvailableSize)
        guard metrics.columns.count == 2 else {
            return (false, "expected 2 semantic command groups, got \(metrics.columns.count)")
        }
        guard sections.contains(where: { section in
            section.rows.contains(where: { $0.command == "Open Finder" })
        }) else {
            return (false, "default command overlay is missing Open Finder")
        }
        let rows = sections.flatMap(\.rows)
        let missingDefaultBindings = Config.default.keymap.compactMap { binding -> String? in
            let expected = CommandOverlayRow(
                key: commandOverlayKeyDescription(binding.key),
                command: commandOverlayCommand(for: binding.action),
                detail: commandOverlayDescription(for: binding.action)
            )
            guard rows.contains(where: {
                $0.key == expected.key
                    && $0.command == expected.command
                    && $0.detail == expected.detail
            }) else {
                return "\(expected.key) \(expected.command)"
            }
            return nil
        }
        guard missingDefaultBindings.isEmpty else {
            return (
                false,
                "default command overlay is missing bindings: \(missingDefaultBindings.joined(separator: ", "))"
            )
        }
        guard metrics.columns[1].first?.title == CommandOverlayCategory.system.title else {
            return (false, "default command overlay does not place System commands at the top of the right column")
        }
        let widestMeaningText = sections.flatMap(\.rows).map { row in
            max(
                CommandOverlayLayout.measure(row.command, font: CommandOverlayLayout.commandFont).width,
                CommandOverlayLayout.measure(row.detail, font: CommandOverlayLayout.detailFont).width
            )
        }.max() ?? 0
        guard widestMeaningText + CommandOverlayLayout.textFitPadding <= metrics.commandColumnWidth else {
            return (
                false,
                "default command overlay text would truncate: widest=\(widestMeaningText) column=\(metrics.commandColumnWidth)"
            )
        }

        let viewSize = CommandOverlayLayout.windowSize(
            forContentSize: metrics.contentSize,
            availableSize: regularAvailableSize
        )

        guard let snapshot = debugSnapshot(metrics: metrics, viewSize: viewSize) else {
            return (false, "command overlay did not produce a debug layout snapshot")
        }
        guard snapshot.titleText == CommandOverlayLayout.titleText else {
            return (false, "bad command overlay title: \(snapshot.titleText)")
        }
        let expectedTitleWidth = CommandOverlayLayout.measure(
            CommandOverlayLayout.titleText,
            font: CommandOverlayLayout.titleFont
        ).width
        guard snapshot.titleFrame.width >= expectedTitleWidth else {
            return (
                false,
                "command overlay title clipped: title=\(snapshot.titleFrame.debugDescription) expectedWidth=\(expectedTitleWidth)"
            )
        }
        guard snapshot.columnFrames.count == 2, let separator = snapshot.separatorFrame else {
            return (false, "expected 2 rendered columns with separator, got \(snapshot.columnFrames.count)")
        }

        let left = snapshot.columnFrames[0]
        let right = snapshot.columnFrames[1]
        let midX = snapshot.columnsBounds.midX
        let rightEdgeDelta = abs(right.maxX - snapshot.columnsBounds.maxX)
        let hasRealSplit = left.minX == snapshot.columnsBounds.minX
            && left.maxX < midX
            && separator.minX > left.maxX
            && separator.maxX < right.minX
            && right.minX > midX
            && rightEdgeDelta <= 1
        guard hasRealSplit else {
            return (
                false,
                "bad command overlay split: bounds=\(snapshot.columnsBounds.debugDescription) left=\(left.debugDescription) separator=\(separator.debugDescription) right=\(right.debugDescription)"
            )
        }
        guard snapshot.documentBounds.width <= snapshot.viewportBounds.width + 1,
              right.maxX <= snapshot.viewportBounds.maxX + 1
        else {
            return (
                false,
                "command overlay content clips horizontally: viewport=\(snapshot.viewportBounds.debugDescription) document=\(snapshot.documentBounds.debugDescription) right=\(right.debugDescription)"
            )
        }
        guard snapshot.scrollBarFrame.minX >= snapshot.scrollViewFrame.maxX + CommandOverlayLayout.scrollBarGap - 1 else {
            return (
                false,
                "command overlay scrollbar overlaps text area: scrollView=\(snapshot.scrollViewFrame.debugDescription) scrollBar=\(snapshot.scrollBarFrame.debugDescription)"
            )
        }
        guard !snapshot.scrollBarHidden,
              snapshot.scrollBarScrollable,
              snapshot.scrollBarFrame.width >= CommandOverlayLayout.scrollBarWidth - 1
        else {
            return (
                false,
                "command overlay scrollbar is not visible on first layout: hidden=\(snapshot.scrollBarHidden) scrollable=\(snapshot.scrollBarScrollable) frame=\(snapshot.scrollBarFrame.debugDescription) rowsHeight=\(metrics.rowsHeight) viewHeight=\(viewSize.height) viewport=\(snapshot.viewportBounds.debugDescription) document=\(snapshot.documentBounds.debugDescription)"
            )
        }
        if let failure = rowLayoutFailure(snapshot.rowSnapshots, expectedCount: rows.count) {
            return (false, "regular command overlay row layout failed: \(failure)")
        }

        let compactAvailableSize = CGSize(width: 760, height: 760)
        let regularWidthOnCompactScreen = CommandOverlayLayout.windowWidth(
            forContentSize: CommandOverlayMetrics(sections: sections).contentSize,
            availableHeight: compactAvailableSize.height
        )
        guard regularWidthOnCompactScreen > compactAvailableSize.width else {
            return (
                false,
                "compact verification width is too wide to trigger compact mode: required=\(regularWidthOnCompactScreen) available=\(compactAvailableSize.width)"
            )
        }
        let compactMetrics = CommandOverlayMetrics.fitting(sections: sections, availableSize: compactAvailableSize)
        guard compactMetrics.columns.count == 1 else {
            return (false, "narrow command overlay should use one column, got \(compactMetrics.columns.count)")
        }
        let compactViewSize = CommandOverlayLayout.windowSize(
            forContentSize: compactMetrics.contentSize,
            availableSize: compactAvailableSize
        )
        guard let compactSnapshot = debugSnapshot(metrics: compactMetrics, viewSize: compactViewSize) else {
            return (false, "compact command overlay did not produce a debug layout snapshot")
        }
        guard compactSnapshot.separatorFrame == nil,
              compactSnapshot.columnFrames.count == 1,
              let compactColumn = compactSnapshot.columnFrames.first
        else {
            return (
                false,
                "compact command overlay should render one column with no separator: columns=\(compactSnapshot.columnFrames.count) separator=\(String(describing: compactSnapshot.separatorFrame))"
            )
        }
        let compactRowWidth = compactMetrics.keyColumnWidth
            + CommandOverlayLayout.rowGap
            + compactMetrics.commandColumnWidth
        guard compactSnapshot.documentBounds.width <= compactSnapshot.viewportBounds.width + 1,
              compactColumn.maxX <= compactSnapshot.viewportBounds.maxX + 1,
              compactRowWidth <= compactColumn.width + 1
        else {
            return (
                false,
                "compact command overlay clips horizontally: viewport=\(compactSnapshot.viewportBounds.debugDescription) document=\(compactSnapshot.documentBounds.debugDescription) column=\(compactColumn.debugDescription) rowWidth=\(compactRowWidth)"
            )
        }
        guard !compactSnapshot.scrollBarHidden,
              compactSnapshot.scrollBarScrollable,
              compactSnapshot.scrollBarFrame.minX >= compactSnapshot.scrollViewFrame.maxX + CommandOverlayLayout.scrollBarGap - 1
        else {
            return (
                false,
                "compact command overlay scrollbar is missing or overlapping: hidden=\(compactSnapshot.scrollBarHidden) scrollable=\(compactSnapshot.scrollBarScrollable) scrollView=\(compactSnapshot.scrollViewFrame.debugDescription) scrollBar=\(compactSnapshot.scrollBarFrame.debugDescription)"
            )
        }
        if let failure = rowLayoutFailure(compactSnapshot.rowSnapshots, expectedCount: rows.count) {
            return (false, "compact command overlay row layout failed: \(failure)")
        }

        return (
            true,
            "command overlay regular and compact layouts verified: regularViewport=\(snapshot.viewportBounds.debugDescription) compactViewport=\(compactSnapshot.viewportBounds.debugDescription) compactColumn=\(compactColumn.debugDescription)"
        )
    }

    private static func rowLayoutFailure(
        _ snapshots: [CommandOverlayDebugRowSnapshot],
        expectedCount: Int
    ) -> String? {
        guard snapshots.count == expectedCount else {
            return "expected \(expectedCount) rows, got \(snapshots.count)"
        }
        for row in snapshots {
            let keyWidth = CommandOverlayLayout.measure(row.key, font: CommandOverlayLayout.keyFont).width
            let commandWidth = CommandOverlayLayout.measure(row.command, font: CommandOverlayLayout.commandFont).width
            let detailWidth = CommandOverlayLayout.measure(row.detail, font: CommandOverlayLayout.detailFont).width
            if row.keyFrame.width + 1 < keyWidth {
                return "key text clips for \(row.key): frame=\(row.keyFrame.debugDescription) required=\(keyWidth)"
            }
            if row.commandFrame.width + 1 < commandWidth {
                return "command text clips for \(row.command): frame=\(row.commandFrame.debugDescription) required=\(commandWidth)"
            }
            if row.detailFrame.width + 1 < detailWidth {
                return "detail text clips for \(row.command): frame=\(row.detailFrame.debugDescription) required=\(detailWidth)"
            }
            let visibleFrames = [row.keyFrame, row.commandFrame, row.detailFrame]
            let fieldDrawingInsetTolerance: CGFloat = 2.5
            if visibleFrames.contains(where: {
                $0.minX < row.bounds.minX - fieldDrawingInsetTolerance
                    || $0.maxX > row.bounds.maxX + fieldDrawingInsetTolerance
                    || $0.minY < row.bounds.minY - fieldDrawingInsetTolerance
                    || $0.maxY > row.bounds.maxY + fieldDrawingInsetTolerance
            }) {
                return "row content escapes bounds for \(row.command): bounds=\(row.bounds.debugDescription) frames=\(visibleFrames.map(\.debugDescription))"
            }
            let expectedAccessibilityLabel = spokenAccessibilityText("\(row.key): \(row.command). \(row.detail)")
            if row.accessibilityLabel != expectedAccessibilityLabel {
                return "row accessibility label mismatch for \(row.command): \(String(describing: row.accessibilityLabel))"
            }
        }
        return nil
    }

    private static func debugSnapshot(
        metrics: CommandOverlayMetrics,
        viewSize: CGSize
    ) -> CommandOverlayDebugLayoutSnapshot? {
        let view = CommandOverlayView(
            columns: metrics.columns,
            keyColumnWidth: metrics.keyColumnWidth,
            commandColumnWidth: metrics.commandColumnWidth,
            rowsHeight: metrics.rowsHeight
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: viewSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: viewSize)
        view.prepareForFirstDisplay()
        return view.debugLayoutSnapshot()
    }
}

@MainActor
enum VisualArtifactVerification {
    static func verifySavedArtifacts() -> (passed: Bool, message: String) {
        do {
            let directory = try artifactDirectory()
            let sections = commandOverlaySections(
                for: Config.default.keymap,
                dragModifier: Config.default.dragModifier,
                zones: Config.default.zones
            )

            let regular = try renderCommandOverlayArtifact(
                sections: sections,
                availableSize: CGSize(width: 2200, height: 760),
                url: directory.appendingPathComponent("command-overlay-regular.png")
            )
            guard regular.isNonBlank, regular.hasReadableRange else {
                return (false, "regular command overlay artifact failed pixel rules: \(regular.description)")
            }

            let compact = try renderCommandOverlayArtifact(
                sections: sections,
                availableSize: CGSize(width: 760, height: 760),
                url: directory.appendingPathComponent("command-overlay-compact.png")
            )
            guard compact.isNonBlank, compact.hasReadableRange else {
                return (false, "compact command overlay artifact failed pixel rules: \(compact.description)")
            }

            let borderView = BorderView(border: BorderConfig(width: 4, colorHex: "#4DA3FF"), cornerRadius: 18)
            let border = try renderArtifact(
                view: borderView,
                size: CGSize(width: 320, height: 200),
                url: directory.appendingPathComponent("focus-border.png")
            )
            guard border.hasBlueSignal, border.centerIsClear else {
                return (false, "focus border artifact failed pixel rules: \(border.description)")
            }

            let hudArtifacts = try [
                ("hud-info.png", HUDView(message: "Command completed", tone: .info)),
                ("hud-success.png", HUDView(message: "Layout saved", tone: .success)),
                ("hud-warning.png", HUDView(message: "Window minimum reached", tone: .warning)),
                ("hud-error.png", HUDView(message: "Frame write failed", tone: .error))
            ].map { name, view in
                try renderArtifact(
                    view: view,
                    size: CGSize(width: 360, height: HUDView.height),
                    url: directory.appendingPathComponent(name)
                )
            }
            guard hudArtifacts.allSatisfy({ $0.isNonBlank && $0.hasReadableRange }) else {
                return (false, "HUD artifacts failed pixel rules: \(hudArtifacts.map(\.description).joined(separator: "; "))")
            }
            if let failure = hudAccessibilityOrContrastFailure() {
                return (false, "HUD accessibility or contrast failed: \(failure)")
            }

            let workbenchArtifacts = try renderWorkbenchArtifacts(directory: directory)
            guard workbenchArtifacts.allSatisfy({ $0.isNonBlank && $0.hasReadableRange }) else {
                return (false, "workbench artifacts failed pixel rules: \(workbenchArtifacts.map(\.description).joined(separator: "; "))")
            }

            return (
                true,
                "visual artifacts verified in \(directory.path): \(regular.description); \(compact.description); \(border.description); \(workbenchArtifacts.map(\.description).joined(separator: "; "))"
            )
        } catch {
            return (false, "visual artifact verification failed: \(String(describing: error))")
        }
    }

    private static func renderWorkbenchArtifacts(directory: URL) throws -> [VisualArtifactStats] {
        let fixture = try workbenchFixture()
        let artifactDirectory = directory.appendingPathComponent("workbench-store", isDirectory: true)
        let controller = LayoutWorkbenchController(
            worldActor: WorldActor(),
            snapshotQuality: { .complete },
            applyPlan: { _, _ in true },
            activateManagedRules: { _ in },
            openAccessibilitySettings: {},
            namedLayoutsStore: NamedLayoutsStore(url: artifactDirectory.appendingPathComponent("layouts.json")),
            managedRulesStore: ManagedRulesStore(url: artifactDirectory.appendingPathComponent("rules.json"))
        )
        controller.show()
        guard let content = controller.debugWindow()?.contentView else {
            throw VisualArtifactError.renderFailed("workbench window did not create content")
        }
        defer { controller.close() }
        let size = CGSize(width: 1020, height: 640)
        var artifacts: [VisualArtifactStats] = []

        controller.debugPresent(
            workbenchPresentation(in: fixture.world, runtime: fixture.runtime, snapshotQuality: .complete),
            planned: fixture.plan,
            intent: .resize(windowID: fixture.first, direction: .right, delta: 0.10),
            selectedWindowID: fixture.floating
        )
        content.appearance = NSAppearance(named: .aqua)
        artifacts.append(try renderArtifact(
            view: content,
            size: size,
            url: directory.appendingPathComponent("workbench-ready-light.png")
        ))
        content.appearance = NSAppearance(named: .darkAqua)
        artifacts.append(try renderArtifact(
            view: content,
            size: size,
            url: directory.appendingPathComponent("workbench-ready-dark.png")
        ))
        content.appearance = NSAppearance(named: .aqua)
        artifacts.append(try renderArtifact(
            view: content,
            size: CGSize(width: 860, height: 520),
            url: directory.appendingPathComponent("workbench-minimum-size.png")
        ))

        controller.debugPresent(workbenchPresentation(
            in: fixture.world,
            runtime: fixture.runtime,
            snapshotQuality: .permissionDenied("Accessibility permission missing")
        ))
        artifacts.append(try renderArtifact(
            view: content,
            size: size,
            url: directory.appendingPathComponent("workbench-permission.png")
        ))

        controller.debugPresent(workbenchPresentation(
            in: fixture.world,
            runtime: fixture.runtime,
            snapshotQuality: .partial([AXWindowReadError(windowID: nil, pid: nil, message: "partial")])
        ))
        artifacts.append(try renderArtifact(
            view: content,
            size: size,
            url: directory.appendingPathComponent("workbench-partial-inventory.png")
        ))

        controller.debugPresent(workbenchPresentation(
            in: fixture.constrainedWorld,
            runtime: fixture.runtime,
            snapshotQuality: .complete
        ))
        artifacts.append(try renderArtifact(
            view: content,
            size: size,
            url: directory.appendingPathComponent("workbench-constraint-conflict.png")
        ))

        controller.debugPresent(workbenchPresentation(
            in: fixture.emptyWorld,
            runtime: .empty,
            snapshotQuality: .complete
        ))
        artifacts.append(try renderArtifact(
            view: content,
            size: size,
            url: directory.appendingPathComponent("workbench-empty-space.png")
        ))

        controller.debugPresent(workbenchPresentation(
            in: fixture.world,
            runtime: fixture.runtime,
            snapshotQuality: .complete
        ))
        controller.debugShowFailure(WorkbenchPlanExplanation(
            title: "Named layout has unmatched targets",
            reason: "1 window slot and 1 display are unavailable. Unmatched windows will remain floating.",
            canRetryAsPartial: true
        ))
        artifacts.append(try renderArtifact(
            view: content,
            size: size,
            url: directory.appendingPathComponent("workbench-template-mismatch.png")
        ))
        return artifacts
    }

    private static func workbenchFixture() throws -> (
        world: World,
        constrainedWorld: World,
        emptyWorld: World,
        runtime: WorldRuntimeState,
        plan: CommandPlanResult,
        first: WindowID,
        floating: WindowID
    ) {
        let displayID = DisplayID(raw: 1)
        let spaceID = SpaceID(raw: 7)
        let first = WindowID(raw: 101)
        let focused = WindowID(raw: 102)
        let floating = WindowID(raw: 103)
        let detached = WindowID(raw: 104)
        let display = DisplayInfo(
            id: displayID,
            slot: 0,
            fingerprint: "visual-fixture",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
        )
        let windows = [
            metadata(first, bundle: "com.example.editor", title: "Project Editor", frame: CGRect(x: 0, y: 24, width: 860, height: 876)),
            metadata(focused, bundle: "com.example.browser", title: "Documentation", frame: CGRect(x: 860, y: 24, width: 580, height: 876)),
            metadata(floating, bundle: "com.example.terminal", title: "Build Output", frame: CGRect(x: 180, y: 170, width: 720, height: 480)),
            metadata(detached, bundle: "com.example.chat", title: "Messages", frame: CGRect(x: 980, y: 180, width: 380, height: 520))
        ]
        let split = try Split.create(axis: .horizontal, cells: [
            try Cell.create(weight: 1.5, node: .leaf(first)).get(),
            try Cell.create(weight: 1, node: .leaf(focused)).get(),
            try Cell.create(weight: 0.4, node: .void).get()
        ]).get()
        let world = World(
            displays: [displayID: display],
            activeSpace: spaceID,
            spaces: [spaceID: SpaceState(
                id: spaceID,
                displays: [displayID: DisplaySpaceState(
                    displayID: displayID,
                    tree: .split(split),
                    floating: [floating, detached]
                )],
                focused: focused
            )],
            windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }),
            windowDisplay: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, displayID) }),
            windowSpace: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, spaceID) }),
            observedVisibleWindows: [WorkspaceKey(displayID: displayID, spaceID: spaceID): Set(windows.map(\.id))],
            windowConstraints: [first: WindowConstraints(minWidth: 520, minHeight: 360)],
            pendingRules: [:],
            config: .default
        )
        var runtime = worldRuntimeBySettingInteraction(.manualAdjustment, for: first, in: .empty)
        runtime = worldRuntimeBySettingInteraction(.temporarilyDetached(.applicationConstraint), for: detached, in: runtime)
        let resized = try apply(.resizeSplit(first, .right, delta: 0.10), to: world).get()
        let plan = try commandPlan(
            from: world,
            to: resized,
            focusedWindowID: first,
            undoWorld: world,
            generation: LayoutGeneration(raw: 1)
        ).get()
        let constrainedWorld = worldByRecordingObservedConstraints(
            [first: WindowConstraints(minWidth: 2_000)],
            in: world
        )
        let emptyWorld = World(
            displays: [displayID: display],
            activeSpace: spaceID,
            spaces: [spaceID: SpaceState(
                id: spaceID,
                displays: [displayID: DisplaySpaceState(displayID: displayID, tree: .void, floating: [])],
                focused: nil
            )],
            windows: [:],
            windowDisplay: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        return (world, constrainedWorld, emptyWorld, runtime, plan, first, floating)
    }

    private static func metadata(
        _ id: WindowID,
        bundle: String,
        title: String,
        frame: CGRect
    ) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: bundle),
            title: title,
            role: "AXWindow",
            pid: ProcessID(Int32(id.raw)),
            frame: frame,
            isResizable: true,
            isMinimized: false
        )
    }

    private static func hudAccessibilityOrContrastFailure() -> String? {
        let cases: [(String, OverlayTone)] = [
            ("Command completed", .info),
            ("Layout saved", .success),
            ("Window minimum reached", .warning),
            ("Frame write failed", .error)
        ]
        for (message, tone) in cases {
            let view = HUDView(message: message, tone: tone)
            view.frame = CGRect(x: 0, y: 0, width: 360, height: HUDView.height)
            view.layoutSubtreeIfNeeded()
            let snapshot = view.debugSnapshot()
            guard snapshot.accessibilityLabel == message else {
                return "\(tone) accessibility label was \(String(describing: snapshot.accessibilityLabel))"
            }
            guard snapshot.contrastRatio >= 4.5 else {
                return "\(tone) contrast was \(String(format: "%.2f", snapshot.contrastRatio)):1"
            }
            let requiredWidth = CommandOverlayLayout.measure(message, font: HUDView.font).width
            guard snapshot.messageFrame.width + 1 >= requiredWidth else {
                return "\(tone) message clipped: frame=\(snapshot.messageFrame.debugDescription) required=\(requiredWidth)"
            }
        }
        return nil
    }

    private static func renderCommandOverlayArtifact(
        sections: [CommandOverlaySection],
        availableSize: CGSize,
        url: URL
    ) throws -> VisualArtifactStats {
        let metrics = CommandOverlayMetrics.fitting(sections: sections, availableSize: availableSize)
        let size = CommandOverlayLayout.windowSize(
            forContentSize: metrics.contentSize,
            availableSize: availableSize
        )
        let view = CommandOverlayView(
            columns: metrics.columns,
            keyColumnWidth: metrics.keyColumnWidth,
            commandColumnWidth: metrics.commandColumnWidth,
            rowsHeight: metrics.rowsHeight
        )
        view.prepareForFirstDisplay()
        return try renderArtifact(view: view, size: size, url: url)
    }

    private static func artifactDirectory() throws -> URL {
        let path = ProcessInfo.processInfo.environment["NARWHAL_VISUAL_ARTIFACT_DIR"]
            ?? "/private/tmp/narwhal-live-artifacts"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func renderArtifact(view: NSView, size: CGSize, url: URL) throws -> VisualArtifactStats {
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        if let overlay = view as? CommandOverlayView {
            overlay.prepareForFirstDisplay()
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw VisualArtifactError.renderFailed("could not create bitmap rep for \(url.lastPathComponent)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw VisualArtifactError.renderFailed("could not encode PNG for \(url.lastPathComponent)")
        }
        try png.write(to: url, options: .atomic)
        return VisualArtifactStats(rep: rep, url: url)
    }
}

private enum VisualArtifactError: Error {
    case renderFailed(String)
}

private struct VisualArtifactStats {
    let url: URL
    let width: Int
    let height: Int
    let visiblePixels: Int
    let bluePixels: Int
    let luminanceRange: Double
    let centerAlpha: Double

    init(rep: NSBitmapImageRep, url: URL) {
        self.url = url
        width = rep.pixelsWide
        height = rep.pixelsHigh

        var visible = 0
        var blue = 0
        var minLuminance = 1.0
        var maxLuminance = 0.0
        for y in 0..<max(0, rep.pixelsHigh) {
            for x in 0..<max(0, rep.pixelsWide) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let alpha = Double(color.alphaComponent)
                let red = Double(color.redComponent)
                let green = Double(color.greenComponent)
                let blueComponent = Double(color.blueComponent)
                if alpha > 0.04 || red + green + blueComponent > 0.08 {
                    visible += 1
                    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blueComponent
                    minLuminance = min(minLuminance, luminance)
                    maxLuminance = max(maxLuminance, luminance)
                }
                if alpha > 0.2, blueComponent > 0.55, blueComponent > red * 1.25, blueComponent > green * 1.05 {
                    blue += 1
                }
            }
        }

        visiblePixels = visible
        bluePixels = blue
        luminanceRange = maxLuminance - minLuminance
        let centerX = max(0, rep.pixelsWide / 2)
        let centerY = max(0, rep.pixelsHigh / 2)
        centerAlpha = Double(rep.colorAt(x: centerX, y: centerY)?.usingColorSpace(.deviceRGB)?.alphaComponent ?? 0)
    }

    var isNonBlank: Bool {
        visiblePixels > max(20, width * height / 80)
    }

    var hasReadableRange: Bool {
        luminanceRange >= 0.30
    }

    var hasBlueSignal: Bool {
        bluePixels > max(12, (width + height) / 3)
    }

    var centerIsClear: Bool {
        centerAlpha < 0.10
    }

    var description: String {
        "\(url.lastPathComponent) \(width)x\(height) visible=\(visiblePixels) blue=\(bluePixels) lumRange=\(String(format: "%.3f", luminanceRange)) centerAlpha=\(String(format: "%.3f", centerAlpha))"
    }
}

@MainActor
enum FocusBorderVerification {
    static func verifyTiledBorderStaleTargetSuppression() -> (passed: Bool, message: String) {
        _ = NSApplication.shared
        let targetWindow = makeVerificationWindow(
            frame: CGRect(x: 180, y: 180, width: 360, height: 240),
            color: .systemGray
        )
        let overlay = Overlay(border: BorderConfig(width: 2, colorHex: "#4DA3FF"), hud: Config.default.hud)
        defer {
            overlay.stop()
            targetWindow.orderOut(nil)
        }

        targetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let targetID = WindowID(raw: CGWindowID(targetWindow.windowNumber))
        guard let liveFrame = windowServerFrame(for: targetWindow.windowNumber) else {
            return (false, "could not read live target frame for stale tiled border verification")
        }

        let staleFrame = liveFrame.offsetBy(dx: 90, dy: 0)
        let staleResult = overlay.render(OverlayModel.empty.settingTiledBorders([
            FocusBorderTarget(windowID: targetID, frame: staleFrame, cornerRadius: 15)
        ]))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard staleResult.staleTiledBorderTargets == [targetID],
              overlay.debugTiledBorderWindowIDs().isEmpty,
              overlay.debugVisibleTiledBorderCount() == 0 else {
            return (
                false,
                "stale tiled border remained visible: stale=\(staleResult.staleTiledBorderTargets.map(\.description)) visible=\(overlay.debugTiledBorderWindowIDs().map(\.description))"
            )
        }

        guard let refreshedLiveFrame = windowServerFrame(for: targetWindow.windowNumber) else {
            return (false, "could not refresh live target frame after stale suppression")
        }
        let liveResult = overlay.render(OverlayModel.empty.settingTiledBorders([
            FocusBorderTarget(windowID: targetID, frame: refreshedLiveFrame, cornerRadius: 15)
        ]))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard liveResult.staleTiledBorderTargets.isEmpty,
              overlay.debugTiledBorderWindowIDs() == [targetID],
              overlay.debugVisibleTiledBorderCount() == 1 else {
            return (
                false,
                "matching tiled border did not render after stale suppression: stale=\(liveResult.staleTiledBorderTargets.map(\.description)) visible=\(overlay.debugTiledBorderWindowIDs().map(\.description))"
            )
        }

        return (
            true,
            "stale tiled border suppression verified target=\(targetID.description) liveFrame=\(refreshedLiveFrame.debugDescription)"
        )
    }

    static func verifyPerWindowCornerRadii() -> (passed: Bool, message: String) {
        let standardFrame = CGRect(x: 120, y: 90, width: 900, height: 640)
        let dialogFrame = CGRect(x: 200, y: 180, width: 460, height: 260)
        let utilityFrame = CGRect(x: 220, y: 210, width: 260, height: 160)
        let tinyFrame = CGRect(x: 20, y: 20, width: 24, height: 18)

        let standardRadius = focusBorderCornerRadius(frame: standardFrame, traits: .standard)
        let dialogRadius = focusBorderCornerRadius(
            frame: dialogFrame,
            traits: FocusBorderWindowTraits(
                role: "AXWindow",
                subrole: "AXDialog",
                isResizable: false,
                isFullscreen: false
            )
        )
        let utilityRadius = focusBorderCornerRadius(
            frame: utilityFrame,
            traits: FocusBorderWindowTraits(
                role: "AXWindow",
                subrole: "AXFloatingWindow",
                isResizable: false,
                isFullscreen: false
            )
        )
        let fullscreenRadius = focusBorderCornerRadius(
            frame: standardFrame,
            traits: FocusBorderWindowTraits(
                role: "AXWindow",
                subrole: "AXStandardWindow",
                isResizable: true,
                isFullscreen: true
            )
        )
        let tinyRadius = focusBorderCornerRadius(frame: tinyFrame, traits: .standard)

        guard standardRadius == 15 else {
            return (false, "expected standard focus radius 15, got \(standardRadius)")
        }
        guard dialogRadius < standardRadius, utilityRadius < dialogRadius else {
            return (
                false,
                "expected descending per-window radii, got standard=\(standardRadius) dialog=\(dialogRadius) utility=\(utilityRadius)"
            )
        }
        guard fullscreenRadius == 0 else {
            return (false, "expected fullscreen focus radius 0, got \(fullscreenRadius)")
        }
        guard tinyRadius <= Double(min(tinyFrame.width, tinyFrame.height)) / 2 else {
            return (false, "tiny focus radius exceeds half of the frame: radius=\(tinyRadius) frame=\(tinyFrame.debugDescription)")
        }

        let border = BorderConfig(width: 2, colorHex: "#4DA3FF")
        let view = BorderView(border: border, cornerRadius: standardRadius)
        let viewFrame = CGRect(origin: .zero, size: CGSize(width: standardFrame.width + border.width, height: standardFrame.height + border.width))
        view.frame = viewFrame
        view.layoutSubtreeIfNeeded()

        guard let standardSnapshot = view.debugGeometrySnapshot() else {
            return (false, "focus border view did not produce geometry")
        }
        guard standardSnapshot.renderedCornerRadius == standardRadius else {
            return (
                false,
                "rendered standard focus radius mismatch: requested=\(standardRadius) rendered=\(standardSnapshot.renderedCornerRadius)"
            )
        }
        guard standardSnapshot.pathBoundingBox.narwhalApproximatelyEquals(
            standardSnapshot.strokeRect,
            tolerance: 1
        ) else {
            return (
                false,
                "focus border path does not match stroke rect: path=\(standardSnapshot.pathBoundingBox.debugDescription) rect=\(standardSnapshot.strokeRect.debugDescription)"
            )
        }

        view.update(border: border, cornerRadius: utilityRadius)
        view.layoutSubtreeIfNeeded()
        guard let utilitySnapshot = view.debugGeometrySnapshot(),
              utilitySnapshot.renderedCornerRadius == utilityRadius else {
            return (false, "focus border view did not update to utility radius \(utilityRadius)")
        }

        let overlay = Overlay(border: border, hud: Config.default.hud)
        let focusTargetWindow = makeVerificationWindow(frame: standardFrame, color: .systemGray)
        defer {
            focusTargetWindow.orderOut(nil)
        }
        focusTargetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        let visibleWindow = WindowID(raw: CGWindowID(focusTargetWindow.windowNumber))
        let otherWindow = WindowID(raw: 902)
        var focusModel = OverlayModel.empty.showingFocusBorder(FocusBorderTarget(
            windowID: visibleWindow,
            frame: standardFrame,
            cornerRadius: standardRadius
        ))
        overlay.render(focusModel)
        guard overlay.debugFocusBorderWindowID() == visibleWindow,
              overlay.debugFocusBorderIsVisible() else {
            overlay.stop()
            return (false, "focus border overlay did not show for \(visibleWindow.description)")
        }

        let transientUnavailable = reduceFocusedWindowObservation(
            state: FocusedWindowObservationState(
                geometry: FocusedWindowGeometryState(windowID: visibleWindow, frame: standardFrame)
            ),
            input: .unavailable,
            tolerance: 1
        )
        guard transientUnavailable.effects.isEmpty else {
            overlay.stop()
            return (false, "transient focused-window unavailable incorrectly produced a hide effect")
        }
        overlay.render(focusModel)
        guard overlay.debugFocusBorderWindowID() == visibleWindow,
              overlay.debugFocusBorderIsVisible() else {
            overlay.stop()
            return (false, "focus border overlay hid after transient focused-window unavailable")
        }

        focusModel = focusModel.removingWindow(otherWindow)
        overlay.render(focusModel)
        guard overlay.debugFocusBorderWindowID() == visibleWindow,
              overlay.debugFocusBorderIsVisible() else {
            overlay.stop()
            return (false, "focus border overlay hid for unrelated closed window \(otherWindow.description)")
        }

        focusModel = focusModel.removingWindow(visibleWindow)
        overlay.render(focusModel)
        guard overlay.debugFocusBorderWindowID() == nil,
              !overlay.debugFocusBorderIsVisible() else {
            overlay.stop()
            return (false, "focus border overlay stayed visible after closing \(visibleWindow.description)")
        }
        overlay.stop()

        let focusStacking = verifyFocusBorderStacking(cornerRadius: standardRadius)
        guard focusStacking.passed else {
            return focusStacking
        }

        let tiledOverlay = Overlay(border: border, hud: Config.default.hud)
        let firstTargetWindow = makeVerificationWindow(
            frame: CGRect(x: 10, y: 10, width: 420, height: 320),
            color: .systemGray
        )
        let secondTargetWindow = makeVerificationWindow(
            frame: CGRect(x: 460, y: 10, width: 420, height: 320),
            color: .systemBlue
        )
        defer {
            firstTargetWindow.orderOut(nil)
            secondTargetWindow.orderOut(nil)
        }
        firstTargetWindow.orderFrontRegardless()
        secondTargetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        let firstTiled = WindowID(raw: CGWindowID(firstTargetWindow.windowNumber))
        let secondTiled = WindowID(raw: CGWindowID(secondTargetWindow.windowNumber))
        guard let firstLiveFrame = windowServerFrame(for: firstTargetWindow.windowNumber),
              let secondLiveFrame = windowServerFrame(for: secondTargetWindow.windowNumber) else {
            tiledOverlay.stop()
            return (false, "could not read live target frames for tiled border verification")
        }
        let expectedTiledIDs = [firstTiled, secondTiled].sorted { $0.raw < $1.raw }
        var tiledModel = OverlayModel.empty.settingTiledBorders([
            FocusBorderTarget(
                windowID: firstTiled,
                frame: firstLiveFrame,
                cornerRadius: standardRadius
            ),
            FocusBorderTarget(
                windowID: secondTiled,
                frame: secondLiveFrame,
                cornerRadius: dialogRadius
            )
        ])
        tiledOverlay.render(tiledModel)
        guard tiledOverlay.debugTiledBorderWindowIDs() == expectedTiledIDs,
              tiledOverlay.debugVisibleTiledBorderCount() == 2 else {
            tiledOverlay.stop()
            return (false, "tiled border overlay did not show both tiled windows")
        }

        let staleSecondFrame = secondLiveFrame.offsetBy(dx: 80, dy: 0)
        tiledModel = OverlayModel.empty.settingTiledBorders([
            FocusBorderTarget(
                windowID: firstTiled,
                frame: firstLiveFrame,
                cornerRadius: standardRadius
            ),
            FocusBorderTarget(
                windowID: secondTiled,
                frame: staleSecondFrame,
                cornerRadius: dialogRadius
            )
        ])
        let staleRender = tiledOverlay.render(tiledModel)
        guard staleRender.staleTiledBorderTargets == [secondTiled],
              tiledOverlay.debugTiledBorderWindowIDs() == [firstTiled] else {
            let currentFirstFrame = windowServerFrame(for: firstTargetWindow.windowNumber)
            let currentSecondFrame = windowServerFrame(for: secondTargetWindow.windowNumber)
            tiledOverlay.stop()
            return (
                false,
                [
                    "tiled border overlay did not hide stale target frame:",
                    "stale=\(staleRender.staleTiledBorderTargets.map(\.description))",
                    "visible=\(tiledOverlay.debugTiledBorderWindowIDs().map(\.description))",
                    "firstTarget=\(firstLiveFrame.debugDescription)",
                    "firstLive=\(String(describing: currentFirstFrame))",
                    "secondTarget=\(staleSecondFrame.debugDescription)",
                    "secondLive=\(String(describing: currentSecondFrame))"
                ].joined(separator: " ")
            )
        }

        tiledModel = OverlayModel.empty.settingTiledBorders([
            FocusBorderTarget(
                windowID: firstTiled,
                frame: firstLiveFrame,
                cornerRadius: standardRadius
            ),
            FocusBorderTarget(
                windowID: secondTiled,
                frame: secondLiveFrame,
                cornerRadius: dialogRadius
            )
        ])
        tiledOverlay.render(tiledModel)
        guard tiledOverlay.debugTiledBorderWindowIDs() == expectedTiledIDs else {
            tiledOverlay.stop()
            return (false, "tiled border overlay did not restore border after live target frame matched again")
        }

        let focusedTiledModel = tiledModel.showingFocusBorder(FocusBorderTarget(
            windowID: secondTiled,
            frame: secondLiveFrame,
            cornerRadius: standardRadius
        ))
        tiledOverlay.render(focusedTiledModel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        guard tiledOverlay.debugFocusBorderWindowID() == secondTiled,
              tiledOverlay.debugFocusBorderIsVisible() else {
            tiledOverlay.stop()
            return (false, "focus border did not show when focused window was also tiled")
        }
        guard let focusedTiledFocusNumber = tiledOverlay.debugFocusBorderWindowNumber(),
              let focusedTiledGreenNumber = tiledOverlay.debugTiledBorderWindowNumber(for: secondTiled),
              let focusedTiledOrderedNumbers = waitForFrontToBackWindowNumbers(containing: [
                  focusedTiledFocusNumber,
                  focusedTiledGreenNumber,
                  secondTargetWindow.windowNumber
              ]),
              let focusedTiledFocusIndex = focusedTiledOrderedNumbers.firstIndex(of: focusedTiledFocusNumber),
              let focusedTiledGreenIndex = focusedTiledOrderedNumbers.firstIndex(of: focusedTiledGreenNumber),
              let focusedTiledTargetIndex = focusedTiledOrderedNumbers.firstIndex(of: secondTargetWindow.windowNumber)
        else {
            tiledOverlay.stop()
            return (false, "could not verify focused tiled border window-server stacking")
        }
        guard focusedTiledFocusIndex < focusedTiledGreenIndex,
              focusedTiledGreenIndex < focusedTiledTargetIndex else {
            tiledOverlay.stop()
            return (
                false,
                "focused tiled focus border is not above green tiled border and target: focusIndex=\(focusedTiledFocusIndex) greenIndex=\(focusedTiledGreenIndex) targetIndex=\(focusedTiledTargetIndex)"
            )
        }

        secondTargetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))

        guard let postRaiseFocusedTiledOrderedNumbers = waitForFrontToBackWindowNumbers(containing: [
            focusedTiledFocusNumber,
            focusedTiledGreenNumber,
            secondTargetWindow.windowNumber
        ]),
              let postRaiseFocusIndex = postRaiseFocusedTiledOrderedNumbers.firstIndex(of: focusedTiledFocusNumber),
              let postRaiseGreenIndex = postRaiseFocusedTiledOrderedNumbers.firstIndex(of: focusedTiledGreenNumber),
              let postRaiseTargetIndex = postRaiseFocusedTiledOrderedNumbers.firstIndex(of: secondTargetWindow.windowNumber)
        else {
            tiledOverlay.stop()
            return (false, "could not verify focused tiled post-raise window-server stacking")
        }
        guard postRaiseFocusIndex < postRaiseGreenIndex,
              postRaiseGreenIndex < postRaiseTargetIndex else {
            tiledOverlay.stop()
            return (
                false,
                "focused tiled focus border stayed behind target after post-render raise: focusIndex=\(postRaiseFocusIndex) greenIndex=\(postRaiseGreenIndex) targetIndex=\(postRaiseTargetIndex)"
            )
        }
        let focusedTiledStackingMessage = [
            "focused tiled stacking verified",
            "focus=\(focusedTiledFocusNumber)",
            "green=\(focusedTiledGreenNumber)",
            "target=\(secondTargetWindow.windowNumber)"
        ].joined(separator: " ")

        guard let initialSecondFrame = tiledOverlay.debugTiledBorderFrame(for: secondTiled) else {
            tiledOverlay.stop()
            return (false, "tiled border overlay did not expose the initial second tiled border frame")
        }
        let updatedSecondAppKitFrame = CGRect(x: 500, y: 30, width: 520, height: 280)
        secondTargetWindow.setFrame(updatedSecondAppKitFrame, display: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        guard let updatedSecondFrame = windowServerFrame(for: secondTargetWindow.windowNumber) else {
            tiledOverlay.stop()
            return (false, "could not read moved target frame for tiled border verification")
        }
        tiledModel = OverlayModel.empty.settingTiledBorders([
            FocusBorderTarget(
                windowID: firstTiled,
                frame: firstLiveFrame,
                cornerRadius: standardRadius
            ),
            FocusBorderTarget(
                windowID: secondTiled,
                frame: updatedSecondFrame,
                cornerRadius: dialogRadius
            )
        ])
        tiledOverlay.render(tiledModel)
        guard let renderedSecondFrame = tiledOverlay.debugTiledBorderFrame(for: secondTiled),
              renderedSecondFrame.minX == updatedSecondFrame.minX - 1,
              renderedSecondFrame.minX != initialSecondFrame.minX,
              renderedSecondFrame.width == updatedSecondFrame.width + 2,
              renderedSecondFrame.height == updatedSecondFrame.height + 2 else {
            tiledOverlay.stop()
            return (
                false,
                "tiled border overlay did not move and resize an existing tiled border: rendered=\(String(describing: tiledOverlay.debugTiledBorderFrame(for: secondTiled))) expectedTarget=\(updatedSecondFrame.debugDescription)"
            )
        }

        tiledModel = tiledModel.removingWindow(firstTiled)
        tiledOverlay.render(tiledModel)
        guard tiledOverlay.debugTiledBorderWindowIDs() == [secondTiled],
              tiledOverlay.debugVisibleTiledBorderCount() == 1 else {
            tiledOverlay.stop()
            return (false, "tiled border overlay did not hide closed tiled window \(firstTiled.description)")
        }

        tiledModel = OverlayModel.empty.settingTiledBorders([])
        tiledOverlay.render(tiledModel)
        guard tiledOverlay.debugTiledBorderWindowIDs().isEmpty,
              tiledOverlay.debugVisibleTiledBorderCount() == 0 else {
            tiledOverlay.stop()
            return (false, "tiled border overlay did not clear all tiled borders")
        }

        tiledModel = OverlayModel.empty.settingTiledBorders([
            FocusBorderTarget(
                windowID: firstTiled,
                frame: firstLiveFrame,
                cornerRadius: standardRadius
            ),
            FocusBorderTarget(
                windowID: secondTiled,
                frame: updatedSecondFrame,
                cornerRadius: dialogRadius
            )
        ])
        let afterClearRender = tiledOverlay.render(tiledModel)
        guard tiledOverlay.debugTiledBorderWindowIDs() == expectedTiledIDs,
              tiledOverlay.debugVisibleTiledBorderCount() == 2 else {
            tiledOverlay.stop()
            return (
                false,
                [
                    "tiled border overlay did not show tiled windows after a clear:",
                    "stale=\(afterClearRender.staleTiledBorderTargets.map(\.description))",
                    "visible=\(tiledOverlay.debugTiledBorderWindowIDs().map(\.description))",
                    "count=\(tiledOverlay.debugVisibleTiledBorderCount())"
                ].joined(separator: " ")
            )
        }
        tiledOverlay.stop()

        let stacking = verifyTiledBorderStacking(cornerRadius: standardRadius)
        guard stacking.passed else {
            return stacking
        }

        return (
            true,
            "focus/tiled borders verified: focus standard=\(standardRadius) dialog=\(dialogRadius) utility=\(utilityRadius) tiny=\(tinyRadius) path=\(standardSnapshot.pathBoundingBox.debugDescription); \(focusedTiledStackingMessage); \(focusStacking.message); \(stacking.message)"
        )
    }

    private static func verifyFocusBorderStacking(cornerRadius: Double) -> (passed: Bool, message: String) {
        let targetFrame = CGRect(x: 120, y: 120, width: 300, height: 220)
        let coverFrame = CGRect(x: 140, y: 140, width: 260, height: 180)
        let targetWindow = makeVerificationWindow(frame: targetFrame, color: .systemGray)
        let coverWindow = makeVerificationWindow(frame: coverFrame, color: .systemRed)
        let overlay = Overlay(border: BorderConfig(width: 2, colorHex: "#4DA3FF"), hud: Config.default.hud)
        defer {
            overlay.stop()
            targetWindow.orderOut(nil)
            coverWindow.orderOut(nil)
        }

        targetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        let targetID = WindowID(raw: CGWindowID(targetWindow.windowNumber))
        var model = OverlayModel.empty.showingFocusBorder(
            FocusBorderTarget(windowID: targetID, frame: targetFrame, cornerRadius: cornerRadius)
        )
        overlay.render(model)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        guard overlay.debugFocusBorderLevelRawValue() == NSWindow.Level.normal.rawValue else {
            return (false, "focus border window was not at normal window level")
        }
        guard let borderNumber = overlay.debugFocusBorderWindowNumber() else {
            return (false, "focus border window did not expose a window number")
        }
        guard let initialOrderedWindowNumbers = waitForFrontToBackWindowNumbers(containing: [
            borderNumber,
            targetWindow.windowNumber
        ]),
              let initialBorderIndex = initialOrderedWindowNumbers.firstIndex(of: borderNumber),
              let targetIndex = initialOrderedWindowNumbers.firstIndex(of: targetWindow.windowNumber)
        else {
            return (false, "could not verify focus border initial window-server stacking")
        }
        guard initialBorderIndex < targetIndex else {
            return (
                false,
                "focus border was not above focused target: borderIndex=\(initialBorderIndex) targetIndex=\(targetIndex)"
            )
        }

        targetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))

        guard let postRaiseOrderedWindowNumbers = waitForFrontToBackWindowNumbers(containing: [
            borderNumber,
            targetWindow.windowNumber
        ]),
              let postRaiseBorderIndex = postRaiseOrderedWindowNumbers.firstIndex(of: borderNumber),
              let postRaiseTargetIndex = postRaiseOrderedWindowNumbers.firstIndex(of: targetWindow.windowNumber)
        else {
            return (false, "could not verify focus border post-raise window-server stacking")
        }
        guard postRaiseBorderIndex < postRaiseTargetIndex else {
            return (
                false,
                "focus border stayed behind target after post-render raise: borderIndex=\(postRaiseBorderIndex) targetIndex=\(postRaiseTargetIndex)"
            )
        }

        coverWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        guard let staleOrderedWindowNumbers = waitForFrontToBackWindowNumbers(containing: [
            coverWindow.windowNumber,
            borderNumber
        ]),
              let coverIndex = staleOrderedWindowNumbers.firstIndex(of: coverWindow.windowNumber),
              let staleBorderIndex = staleOrderedWindowNumbers.firstIndex(of: borderNumber)
        else {
            return (false, "could not verify stale focus border stacking")
        }
        guard coverIndex < staleBorderIndex else {
            return (
                false,
                "stale focus border stayed above newly fronted floating window: coverIndex=\(coverIndex) borderIndex=\(staleBorderIndex)"
            )
        }

        let coverID = WindowID(raw: CGWindowID(coverWindow.windowNumber))
        model = model.showingFocusBorder(
            FocusBorderTarget(windowID: coverID, frame: coverFrame, cornerRadius: cornerRadius)
        )
        overlay.render(model)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        guard overlay.debugFocusBorderWindowID() == coverID else {
            return (false, "focus border did not retarget to newly focused floating window")
        }
        guard let focusedOrderedWindowNumbers = waitForFrontToBackWindowNumbers(containing: [
            borderNumber,
            coverWindow.windowNumber
        ]),
              let focusedBorderIndex = focusedOrderedWindowNumbers.firstIndex(of: borderNumber),
              let focusedCoverIndex = focusedOrderedWindowNumbers.firstIndex(of: coverWindow.windowNumber)
        else {
            return (false, "could not verify retargeted focus border stacking")
        }
        guard focusedBorderIndex < focusedCoverIndex else {
            return (
                false,
                "retargeted focus border stayed behind floating target: borderIndex=\(focusedBorderIndex) coverIndex=\(focusedCoverIndex)"
            )
        }

        return (
            true,
            "focus border stacking verified border=\(borderNumber) target=\(targetWindow.windowNumber) cover=\(coverWindow.windowNumber)"
        )
    }

    private static func verifyTiledBorderStacking(cornerRadius: Double) -> (passed: Bool, message: String) {
        let targetFrame = CGRect(x: 120, y: 120, width: 300, height: 220)
        let coverFrame = CGRect(x: 140, y: 140, width: 260, height: 180)
        let targetWindow = makeVerificationWindow(frame: targetFrame, color: .systemGray)
        let coverWindow = makeVerificationWindow(frame: coverFrame, color: .systemRed)
        let overlay = Overlay(border: BorderConfig(width: 2, colorHex: "#4DA3FF"), hud: Config.default.hud)
        defer {
            overlay.stop()
            targetWindow.orderOut(nil)
            coverWindow.orderOut(nil)
        }

        targetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        let targetID = WindowID(raw: CGWindowID(targetWindow.windowNumber))
        guard let targetLiveFrame = windowServerFrame(for: targetWindow.windowNumber) else {
            return (false, "could not read live target frame for tiled border stacking")
        }
        overlay.render(OverlayModel.empty.settingTiledBorders([
            FocusBorderTarget(windowID: targetID, frame: targetLiveFrame, cornerRadius: cornerRadius)
        ]))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        coverWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        guard overlay.debugTiledBorderLevelRawValue(for: targetID) == NSWindow.Level.normal.rawValue else {
            return (false, "tiled border window was not at normal window level")
        }
        guard let borderNumber = overlay.debugTiledBorderWindowNumber(for: targetID) else {
            return (false, "tiled border window did not expose a window number")
        }
        guard let orderedWindowNumbers = waitForFrontToBackWindowNumbers(containing: [
            coverWindow.windowNumber,
            borderNumber,
            targetWindow.windowNumber
        ]),
              let coverIndex = orderedWindowNumbers.firstIndex(of: coverWindow.windowNumber),
              let borderIndex = orderedWindowNumbers.firstIndex(of: borderNumber),
              let targetIndex = orderedWindowNumbers.firstIndex(of: targetWindow.windowNumber)
        else {
            return (false, "could not verify tiled border window-server stacking")
        }
        guard coverIndex < borderIndex, borderIndex < targetIndex else {
            return (
                false,
                "tiled border stacking is wrong: coverIndex=\(coverIndex) borderIndex=\(borderIndex) targetIndex=\(targetIndex)"
            )
        }

        targetWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        overlay.render(OverlayModel.empty.settingTiledBorders([
            FocusBorderTarget(windowID: targetID, frame: targetLiveFrame, cornerRadius: cornerRadius)
        ]))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        guard let focusedOrderedWindowNumbers = waitForFrontToBackWindowNumbers(containing: [
            borderNumber,
            targetWindow.windowNumber
        ]),
              let focusedBorderIndex = focusedOrderedWindowNumbers.firstIndex(of: borderNumber),
              let focusedTargetIndex = focusedOrderedWindowNumbers.firstIndex(of: targetWindow.windowNumber)
        else {
            return (false, "could not verify focused tiled border window-server stacking")
        }
        guard focusedBorderIndex < focusedTargetIndex else {
            return (
                false,
                "focused tiled border stayed behind target: borderIndex=\(focusedBorderIndex) targetIndex=\(focusedTargetIndex)"
            )
        }

        return (
            true,
            "tiled border stacking verified cover=\(coverWindow.windowNumber) border=\(borderNumber) target=\(targetWindow.windowNumber)"
        )
    }

    private static func makeVerificationWindow(frame: CGRect, color: NSColor) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = color
        window.isOpaque = true
        window.hasShadow = false
        window.level = .normal
        window.collectionBehavior = [.ignoresCycle]
        return window
    }

    private static func frontToBackWindowNumbers() -> [Int]? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else { return nil }

        return windows.compactMap { window in
            if let number = window[kCGWindowNumber as String] as? CGWindowID {
                return Int(number)
            }
            if let number = window[kCGWindowNumber as String] as? Int {
                return number
            }
            return nil
        }
    }

    private static func windowServerFrame(for windowNumber: Int) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowNumber)
        ) as? [[String: Any]]
        else { return nil }

        for window in windows {
            guard let number = window[kCGWindowNumber as String] as? CGWindowID,
                  Int(number) == windowNumber,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary)
            else { continue }
            return frame
        }
        return nil
    }

    private static func waitForFrontToBackWindowNumbers(
        containing requiredWindowNumbers: [Int],
        timeout: TimeInterval = 0.6
    ) -> [Int]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let numbers = frontToBackWindowNumbers(),
               requiredWindowNumbers.allSatisfy({ numbers.contains($0) }) {
                return numbers
            }
            guard Date() < deadline else { return nil }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
#endif
