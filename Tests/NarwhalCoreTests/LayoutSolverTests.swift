import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Min-size-aware layout solver")
struct LayoutSolverTests {
    @Test("No constraints solve to the existing layout exactly")
    func noConstraintsMatchUnconstrainedLayout() {
        let display = DisplayID(raw: 1)
        let tree = pushSequence([
            (WindowID(raw: 1), Direction.left),
            (WindowID(raw: 2), Direction.right),
            (WindowID(raw: 3), Direction.down),
            (WindowID(raw: 4), Direction.up)
        ])
        let space = spaceState(display: display, tree: tree)
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let gaps = noGaps

        let expected = layout(spaceState: space, displayID: display, frame: frame, gaps: gaps)

        #expect(
            solveLayout(spaceState: space, displayID: display, frame: frame, gaps: gaps, constraints: [:])
                == .solved(layout: expected, status: .exact)
        )
    }

    @Test("Minimum below ideal allocation does not distort layout")
    func nonBindingMinimumKeepsWeightedLayout() {
        let display = DisplayID(raw: 1)
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let tree = pushIntoTree(b, .right, pushIntoTree(a, .left, .void))
        let space = spaceState(display: display, tree: tree)
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let gaps = noGaps
        let expected = layout(spaceState: space, displayID: display, frame: frame, gaps: gaps)

        #expect(
            solveLayout(
                spaceState: space,
                displayID: display,
                frame: frame,
                gaps: gaps,
                constraints: [a: WindowConstraints(minWidth: 500)]
            ) == .solved(layout: expected, status: .exact)
        )
    }

    @Test("Binding minimum takes only the required space from flexible siblings")
    func bindingMinimumUsesWaterFillAllocation() throws {
        let display = DisplayID(raw: 1)
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let d = WindowID(raw: 4)
        let middle = try Split.create(axis: .vertical, cells: [
            try Cell.create(weight: 1, node: .leaf(d)).get(),
            try Cell.create(weight: 1, node: .leaf(c)).get()
        ]).get()
        let tree = Node.split(try Split.create(axis: .horizontal, cells: [
            try Cell.create(weight: 1, node: .leaf(a)).get(),
            try Cell.create(weight: 1, node: .split(middle)).get(),
            try Cell.create(weight: 1, node: .leaf(b)).get()
        ]).get())
        let space = spaceState(display: display, tree: tree)
        let frame = CGRect(x: 0, y: 0, width: 1472, height: 800)
        let gaps = noGaps

        let result = solveLayout(
            spaceState: space,
            displayID: display,
            frame: frame,
            gaps: gaps,
            constraints: [a: WindowConstraints(minWidth: 500)]
        )

        switch result {
        case .solved(let solved, .adjusted(let adjustments)):
            #expect(solved.tiled[a] == CGRect(x: 0, y: 0, width: 500, height: 800))
            #expect(solved.tiled[d] == CGRect(x: 500, y: 0, width: 486, height: 400))
            #expect(solved.tiled[c] == CGRect(x: 500, y: 400, width: 486, height: 400))
            #expect(solved.tiled[b] == CGRect(x: 986, y: 0, width: 486, height: 800))
            #expect(adjustments.count == 1)
            #expect(adjustments.first?.windowID == a)
            #expect(adjustments.first?.reason == .minimumWidth(500))
        default:
            #expect(Bool(false), "Expected adjusted solved layout, got \(String(describing: result))")
        }
    }

    @Test("Unsatisfiable horizontal minimums return a domain failure")
    func unsatisfiableMinimumsReturnReason() {
        let display = DisplayID(raw: 1)
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let tree = pushIntoTree(b, .right, pushIntoTree(a, .left, .void))
        let space = spaceState(display: display, tree: tree)

        let result = solveLayout(
            spaceState: space,
            displayID: display,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            gaps: noGaps,
            constraints: [
                a: WindowConstraints(minWidth: 600),
                b: WindowConstraints(minWidth: 600)
            ]
        )

        #expect(result == .unsatisfiable(UnsatisfiableLayout(
            displayID: display,
            axis: .horizontal,
            available: 1000,
            required: 1200,
            windows: [a, b]
        )))
    }

    @Test("Finder-width clamp is inferred as a width minimum only")
    func inferFinderWidthClamp() {
        let target = CGRect(x: 12, y: 45, width: 490.666_666_666_7, height: 420.5)
        let actual = CGRect(x: 12, y: 45, width: 500, height: 421)
        let observed = inferObservedConstraints(target: target, actual: actual, tolerance: 2)

        #expect(observed == WindowConstraints(minWidth: 500))
        #expect(!frameWriteApproximatelySettled(target: target, actual: actual, tolerance: 2))
    }

    @Test("Origin drift and invalid sizes do not become minimum constraints")
    func inferConstraintsIgnoresNonMinimumSignals() {
        #expect(inferObservedConstraints(
            target: CGRect(x: 0, y: 0, width: 500, height: 400),
            actual: CGRect(x: 12, y: 10, width: 500, height: 400),
            tolerance: 2
        ) == nil)

        #expect(inferObservedConstraints(
            target: CGRect(x: 0, y: 0, width: 500, height: 400),
            actual: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 400),
            tolerance: 2
        ) == nil)
    }

    @Test("Smaller edge-anchored frame is inferred as a maximum constraint")
    func inferMaximumHeightClamp() {
        let target = CGRect(x: 0, y: 30, width: 1504, height: 1562)
        let actual = CGRect(x: 0, y: 132, width: 1504, height: 1455)

        #expect(inferObservedConstraints(
            target: target,
            actual: actual,
            tolerance: 4
        ) == WindowConstraints(maxHeight: 1455, heightAnchor: .max))
    }

    @Test("Maximum constraints cap a leaf inside its allocated cell")
    func maximumConstraintCapsLeafFrame() {
        let display = DisplayID(raw: 1)
        let window = WindowID(raw: 1)
        let frame = CGRect(x: 0, y: 30, width: 1504, height: 1562)
        let space = spaceState(display: display, tree: .leaf(window))

        let result = solveLayout(
            spaceState: space,
            displayID: display,
            frame: frame,
            gaps: noGaps,
            constraints: [window: WindowConstraints(maxHeight: 1455, heightAnchor: .max)]
        )

        #expect(result == .solved(
            layout: Layout(
                tiled: [window: CGRect(x: 0, y: 137, width: 1504, height: 1455)],
                floatingZOrder: [],
                hidden: []
            ),
            status: .adjusted([
                LayoutAdjustment(
                    windowID: window,
                    requested: frame,
                    adjusted: CGRect(x: 0, y: 137, width: 1504, height: 1455),
                    reason: .maximumHeight(1455)
                )
            ])
        ))
    }

    @Test("Browser chrome adjusted frames settle without becoming hard failures")
    func browserChromeAdjustedFramesSettle() {
        let firefoxTarget = CGRect(x: 166, y: 33, width: 1346, height: 873)
        let firefoxActual = CGRect(x: 166, y: 41, width: 1346, height: 864)
        let firefoxEdgeNormalizedTarget = CGRect(x: 40, y: 74, width: 2048, height: 740)
        let firefoxEdgeNormalizedActual = CGRect(x: 40, y: 68, width: 2034, height: 746)
        let workflowPlanTarget = CGRect(x: 756, y: 33, width: 756, height: 873)
        let workflowPlanActual = CGRect(x: 756, y: 33, width: 755, height: 861)
        let systemSettingsTarget = CGRect(x: 756, y: 33, width: 756, height: 873)
        let systemSettingsActual = CGRect(x: 756, y: 33, width: 723, height: 872)

        #expect(frameWriteApproximatelySettled(target: firefoxTarget, actual: firefoxActual, tolerance: 2))
        #expect(frameSizeApproximatelySettled(target: firefoxTarget.size, actual: firefoxActual.size, tolerance: 2))
        #expect(frameWriteApproximatelySettled(
            target: firefoxEdgeNormalizedTarget,
            actual: firefoxEdgeNormalizedActual,
            tolerance: 4
        ))
        #expect(frameWriteApproximatelySettled(
            target: workflowPlanTarget,
            actual: workflowPlanActual,
            tolerance: 4,
            maxEdgeDrift: 16,
            minimumOverlapRatio: 0.98
        ))
        #expect(frameWriteApproximatelySettled(target: systemSettingsTarget, actual: systemSettingsActual, tolerance: 2))
        #expect(frameSizeApproximatelySettled(target: systemSettingsTarget.size, actual: systemSettingsActual.size, tolerance: 2))
    }

    @Test("Same-origin browser minimum expansion does not settle")
    func sameOriginBrowserMinimumExpansionDoesNotSettle() {
        let target = CGRect(x: 0, y: 33, width: 756, height: 357.11)
        let actual = CGRect(x: 0, y: 33, width: 756, height: 375)

        #expect(inferObservedConstraints(
            target: target,
            actual: actual,
            tolerance: 4
        ) == WindowConstraints(minHeight: 375))
        #expect(!frameWriteApproximatelySettled(target: target, actual: actual, tolerance: 4))
        #expect(!frameWriteApproximatelySettled(
            target: target,
            actual: actual,
            tolerance: 4,
            maxEdgeDrift: 16,
            minimumOverlapRatio: 0.98
        ))
    }

    @Test("Terminal character-grid rounding settles without becoming a minimum height")
    func terminalCharacterGridRoundingSettles() {
        let target = CGRect(x: 1504, y: 550.666_666_666_7, width: 1504, height: 520.666_666_666_7)
        let actual = CGRect(x: 1504, y: 551, width: 1507, height: 525)

        #expect(frameWriteApproximatelySettled(target: target, actual: actual, tolerance: 4))
    }

    @Test("Expansion beyond edge-rounding slack remains a minimum-size signal")
    func expansionBeyondEdgeRoundingSlackDoesNotSettle() {
        let target = CGRect(x: 0, y: 0, width: 500, height: 500)
        let actual = CGRect(x: 0, y: 0, width: 500, height: 506)

        #expect(inferObservedConstraints(
            target: target,
            actual: actual,
            tolerance: 4
        ) == WindowConstraints(minHeight: 506))
        #expect(!frameWriteApproximatelySettled(target: target, actual: actual, tolerance: 4))
    }

    @Test("Minimum-size expansion is still inferred as a clamp")
    func minimumSizeExpansionStillInfersClamp() {
        let target = CGRect(x: 0, y: 0, width: 500, height: 400)
        let actual = CGRect(x: 0, y: 0, width: 720, height: 400)

        #expect(inferObservedConstraints(target: target, actual: actual, tolerance: 2) == WindowConstraints(minWidth: 720))
        #expect(!frameWriteApproximatelySettled(target: target, actual: actual, tolerance: 2))
        #expect(!frameSizeApproximatelySettled(target: target.size, actual: actual.size, tolerance: 2))
    }

    @Test("Unchanged distant frames do not count as settled writes")
    func unchangedDistantFramesDoNotSettle() {
        #expect(!frameWriteApproximatelySettled(
            target: CGRect(x: 0, y: 0, width: 700, height: 500),
            actual: CGRect(x: 900, y: 600, width: 700, height: 500),
            tolerance: 2
        ))
    }

    @Test("Constraint observations merge monotonically")
    func observedConstraintsMergeByMaximum() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 1)
        let world = World(
            displays: [
                display: DisplayInfo(
                    id: display,
                    slot: 0,
                    fingerprint: nil,
                    frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
                )
            ],
            activeSpace: space,
            spaces: [space: SpaceState(id: space, displays: [:], focused: nil)],
            windows: [window: metadata(for: window)],
            windowDisplay: [window: display],
            windowConstraints: [window: WindowConstraints(minWidth: 500, minHeight: 300)],
            pendingRules: [:],
            config: .default
        )

        let next = recordObservedConstraints(WindowConstraints(minWidth: 490, minHeight: 350), for: window, in: world)

        #expect(next.windowConstraints[window] == WindowConstraints(minWidth: 500, minHeight: 350))

        let commandNext = try apply(
            .windowConstraintObserved(window, WindowConstraints(minWidth: 525, minHeight: 325)),
            to: next
        ).get()

        #expect(commandNext.windowConstraints[window] == WindowConstraints(minWidth: 525, minHeight: 350))
    }

    @Test("Maximum observations merge to the stricter bound and preserve its anchor")
    func maximumConstraintsMergeByMinimum() {
        let existing = WindowConstraints(maxHeight: 1455, heightAnchor: .max)
        let looser = WindowConstraints(maxHeight: 1500, heightAnchor: .min)
        let stricter = WindowConstraints(maxHeight: 1400, heightAnchor: .center)

        #expect(existing.merged(with: looser) == existing)
        #expect(existing.merged(with: stricter) == stricter)
    }

    private var noGaps: Gaps {
        Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0))
    }

    private func pushSequence(_ entries: [(WindowID, Direction)]) -> Node {
        entries.reduce(Node.void) { tree, entry in
            pushIntoTree(entry.0, entry.1, tree)
        }
    }

    private func spaceState(display: DisplayID, tree: Node) -> SpaceState {
        SpaceState(
            id: SpaceID(raw: 1),
            displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
            focused: nil
        )
    }

    private func metadata(for window: WindowID) -> WindowMetadata {
        WindowMetadata(
            id: window,
            bundleID: BundleID(raw: "com.example"),
            title: "Window \(window.raw)",
            role: "AXWindow",
            pid: 42,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isResizable: true,
            isMinimized: false
        )
    }
}
