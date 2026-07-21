import CoreGraphics
import NarwhalCore
import Testing

@Suite("Named layouts")
struct NamedLayoutsTests {
    @Test("Matching is deterministic, one-to-one, and preserves a window already on the target display")
    func deterministicMatching() throws {
        let layout = sampleLayout()
        let first = candidate(id: 1, x: 0, displaySlot: 1)
        let alreadyOnTarget = candidate(id: 2, x: 500, displaySlot: 0)
        let browser = candidate(id: 3, bundleID: "com.example.browser", title: "Docs", x: 900, displaySlot: 0)

        let result = try matchNamedLayout(
            layout,
            candidates: [browser, first, alreadyOnTarget],
            availableDisplaySlots: [0]
        ).get()

        #expect(result.matches == [
            MatchedLayoutSlot(slotID: LayoutSlotID(rawValue: "editor"), windowID: alreadyOnTarget.window.id, targetDisplaySlot: 0),
            MatchedLayoutSlot(slotID: LayoutSlotID(rawValue: "docs"), windowID: browser.window.id, targetDisplaySlot: 0)
        ])
        #expect(result.unmatchedWindows == [first.window.id])
        #expect(result.isComplete)
    }

    @Test("Missing evidence is explicit")
    func unmatchedSlotsWindowsAndDisplaysAreReported() throws {
        let layout = NamedLayout(
            id: NamedLayoutID(rawValue: "dual"),
            name: "Dual display",
            displays: [
                sampleLayout().displays[0],
                DisplayLayoutTemplate(displaySlot: 1, root: .slot(slot("chat", bundleID: "com.example.chat")))
            ]
        )
        let unrelated = candidate(id: 8, bundleID: "com.example.mail", title: "Inbox", x: 0, displaySlot: 0)

        let result = try matchNamedLayout(
            layout,
            candidates: [unrelated],
            availableDisplaySlots: [0]
        ).get()

        #expect(result.matches.isEmpty)
        #expect(result.unmatchedSlots.map(\.slotID) == [LayoutSlotID(rawValue: "editor"), LayoutSlotID(rawValue: "docs")])
        #expect(result.unmatchedWindows == [unrelated.window.id])
        #expect(result.missingDisplaySlots == [1])
        #expect(!result.isComplete)
    }

    @Test("Template validation rejects malformed structure and identity")
    func validation() {
        let duplicate = NamedLayout(
            id: NamedLayoutID(rawValue: "duplicate"),
            name: "Duplicate",
            displays: [
                DisplayLayoutTemplate(
                    displaySlot: 0,
                    root: .split(axis: .horizontal, cells: [
                        LayoutTemplateCell(weight: 1, node: .slot(slot("same", bundleID: "a"))),
                        LayoutTemplateCell(weight: 1, node: .slot(slot("same", bundleID: "b")))
                    ])
                )
            ]
        )
        #expect(validateNamedLayout(duplicate) == .failure(.duplicateSlotID(LayoutSlotID(rawValue: "same"))))

        let invalidRegex = NamedLayout(
            id: NamedLayoutID(rawValue: "regex"),
            name: "Regex",
            displays: [DisplayLayoutTemplate(
                displaySlot: 0,
                root: .slot(LayoutTemplateSlot(
                    id: LayoutSlotID(rawValue: "bad"),
                    matcher: LayoutWindowMatcher(bundleID: "app", title: .regex("["))
                ))
            )]
        )
        #expect(validateNamedLayout(invalidRegex) == .failure(.invalidTitleRegex(
            slot: LayoutSlotID(rawValue: "bad"),
            pattern: "["
        )))
    }

    @Test("Resolving a partial template collapses empty branches without invalid splits")
    func partialResolutionCollapsesEmptyBranches() throws {
        let layout = sampleLayout()
        let editorID = WindowID(raw: 11)

        let resolved = resolvedTemplateNode(
            layout.displays[0].root,
            assignments: [LayoutSlotID(rawValue: "editor"): editorID]
        )

        #expect(resolved == .leaf(editorID))
    }

    @Test("Application replaces the selected Space tree and leaves unmatched windows floating")
    func applicationBuildsPlannedWorld() throws {
        let displayID = DisplayID(raw: 1)
        let spaceID = SpaceID(raw: 7)
        let editor = candidate(id: 1, x: 0, displaySlot: 0).window
        let browser = candidate(id: 2, bundleID: "com.example.browser", title: "Docs", x: 400, displaySlot: 0).window
        let mail = candidate(id: 3, bundleID: "com.example.mail", title: "Inbox", x: 800, displaySlot: 0).window
        let currentTree = try Split.create(axis: .horizontal, cells: [
            try Cell.create(weight: 1, node: .leaf(editor.id)).get(),
            try Cell.create(weight: 1, node: .leaf(mail.id)).get()
        ]).get()
        let world = World(
            displays: [displayID: DisplayInfo(
                id: displayID,
                slot: 0,
                fingerprint: "display",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)
            )],
            activeSpace: spaceID,
            spaces: [spaceID: SpaceState(
                id: spaceID,
                displays: [displayID: DisplaySpaceState(
                    displayID: displayID,
                    tree: .split(currentTree),
                    floating: [browser.id]
                )],
                focused: editor.id
            )],
            windows: [editor.id: editor, browser.id: browser, mail.id: mail],
            windowDisplay: [editor.id: displayID, browser.id: displayID, mail.id: displayID],
            windowSpace: [editor.id: spaceID, browser.id: spaceID, mail.id: spaceID],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let application = try applyNamedLayout(
            sampleLayout(),
            to: spaceID,
            in: world,
            allowPartial: false
        ).get()

        let state = try #require(application.world.spaces[spaceID]?.displays[displayID])
        #expect(occupiedWindows(in: state.tree) == [editor.id, browser.id])
        #expect(state.floating == [mail.id])
        #expect(Set(application.layout.tiled.keys) == [editor.id, browser.id])
    }

    @Test("Four through eight windows fill equal rows and columns")
    func fourThroughEightWindowsFillEqualRowsAndColumns() throws {
        for count in 4...8 {
            for axis in Axis.allCases {
                let world = matrixWorld(windowCount: count)
                let application = try applyNamedLayout(
                    matrixLayout(windowCount: count, axis: axis),
                    to: SpaceID(raw: 7),
                    in: world,
                    allowPartial: false
                ).get()
                let actualFrames = application.layout.tiled.values.sorted { lhs, rhs in
                    axis == .horizontal ? lhs.minX < rhs.minX : lhs.minY < rhs.minY
                }
                let visibleFrame = world.displays[DisplayID(raw: 1)]!.visibleFrame

                #expect(actualFrames.count == count)
                #expect(
                    isEqualRepresentableAxisLayout(actualFrames, axis: axis, in: visibleFrame),
                    "Uneven \(axis.rawValue) layout at count \(count): \(actualFrames)"
                )
            }
        }
    }

    @Test("Saving a tree never stores a window ID and only includes requested title hints")
    func capturesSemanticTemplate() throws {
        let displayID = DisplayID(raw: 1)
        let spaceID = SpaceID(raw: 7)
        let editor = candidate(id: 1, title: "Secret Project", x: 0, displaySlot: 0).window
        let world = World(
            displays: [displayID: DisplayInfo(
                id: displayID,
                slot: 0,
                fingerprint: nil,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
            )],
            activeSpace: spaceID,
            spaces: [spaceID: SpaceState(
                id: spaceID,
                displays: [displayID: DisplaySpaceState(displayID: displayID, tree: .leaf(editor.id), floating: [])],
                focused: editor.id
            )],
            windows: [editor.id: editor],
            windowDisplay: [editor.id: displayID],
            windowSpace: [editor.id: spaceID],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let withoutTitle = try namedLayout(
            id: NamedLayoutID(rawValue: "saved"),
            name: "Saved",
            revision: 1,
            from: spaceID,
            in: world
        ).get()
        let withTitle = try namedLayout(
            id: NamedLayoutID(rawValue: "saved"),
            name: "Saved",
            revision: 2,
            from: spaceID,
            in: world,
            includeTitleHints: [editor.id]
        ).get()

        guard case .slot(let plainSlot) = withoutTitle.displays[0].root,
              case .slot(let titledSlot) = withTitle.displays[0].root else {
            Issue.record("Expected captured slots")
            return
        }
        #expect(plainSlot.matcher.title == nil)
        #expect(titledSlot.matcher.title == .exact("Secret Project"))
    }

    private func sampleLayout() -> NamedLayout {
        NamedLayout(
            id: NamedLayoutID(rawValue: "coding"),
            name: "Coding",
            displays: [
                DisplayLayoutTemplate(
                    displaySlot: 0,
                    root: .split(axis: .horizontal, cells: [
                        LayoutTemplateCell(weight: 2, node: .slot(slot("editor", bundleID: "com.example.editor"))),
                        LayoutTemplateCell(weight: 1, node: .slot(slot(
                            "docs",
                            bundleID: "com.example.browser",
                            title: .regex("Docs")
                        )))
                    ])
                )
            ]
        )
    }

    private func matrixLayout(windowCount: Int, axis: Axis) -> NamedLayout {
        NamedLayout(
            id: NamedLayoutID(rawValue: "matrix-\(axis.rawValue)-\(windowCount)"),
            name: "Matrix \(axis.rawValue) \(windowCount)",
            displays: [
                DisplayLayoutTemplate(
                    displaySlot: 0,
                    root: .split(
                        axis: axis,
                        cells: (1...windowCount).map { index in
                            LayoutTemplateCell(
                                weight: 1,
                                node: .slot(slot("window-\(index)", bundleID: "com.example.editor"))
                            )
                        }
                    )
                )
            ]
        )
    }

    private func matrixWorld(windowCount: Int) -> World {
        let displayID = DisplayID(raw: 1)
        let spaceID = SpaceID(raw: 7)
        let windows = (1...windowCount).map { index in
            candidate(id: index, x: Double(index * 20), displaySlot: 0).window
        }
        return World(
            displays: [displayID: DisplayInfo(
                id: displayID,
                slot: 0,
                fingerprint: "display",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)
            )],
            activeSpace: spaceID,
            spaces: [spaceID: SpaceState(
                id: spaceID,
                displays: [displayID: DisplaySpaceState(
                    displayID: displayID,
                    tree: .void,
                    floating: windows.map(\.id)
                )],
                focused: windows.first?.id
            )],
            windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }),
            windowDisplay: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, displayID) }),
            windowSpace: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, spaceID) }),
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private func isEqualRepresentableAxisLayout(
        _ frames: [CGRect],
        axis: Axis,
        in outer: CGRect
    ) -> Bool {
        guard let first = frames.first, let last = frames.last else { return false }
        let lengths = frames.map { axis == .horizontal ? $0.width : $0.height }
        guard let minimumLength = lengths.min(), let maximumLength = lengths.max() else { return false }
        let coversOuter = axis == .horizontal
            ? abs(first.minX - outer.minX) <= 0.000_001 && abs(last.maxX - outer.maxX) <= 0.000_001
            : abs(first.minY - outer.minY) <= 0.000_001 && abs(last.maxY - outer.maxY) <= 0.000_001
        let sharedEdges = zip(frames, frames.dropFirst()).allSatisfy { leading, trailing in
            axis == .horizontal
                ? abs(leading.maxX - trailing.minX) <= 0.000_001
                : abs(leading.maxY - trailing.minY) <= 0.000_001
        }
        let crossAxisMatches = frames.allSatisfy { frame in
            axis == .horizontal
                ? abs(frame.minY - outer.minY) <= 0.000_001 && abs(frame.height - outer.height) <= 0.000_001
                : abs(frame.minX - outer.minX) <= 0.000_001 && abs(frame.width - outer.width) <= 0.000_001
        }
        let internalBoundariesAreRepresentable = frames.dropFirst().allSatisfy { frame in
            let boundary = axis == .horizontal ? frame.minX : frame.minY
            return abs(boundary - boundary.rounded()) <= 0.000_001
        }
        return coversOuter
            && sharedEdges
            && crossAxisMatches
            && internalBoundariesAreRepresentable
            && maximumLength - minimumLength <= 1
    }

    private func slot(
        _ id: String,
        bundleID: String,
        title: LayoutTitleMatcher? = nil
    ) -> LayoutTemplateSlot {
        LayoutTemplateSlot(
            id: LayoutSlotID(rawValue: id),
            matcher: LayoutWindowMatcher(bundleID: bundleID, role: "AXWindow", title: title)
        )
    }

    private func candidate(
        id: Int,
        bundleID: String = "com.example.editor",
        title: String = "Project",
        x: Double,
        displaySlot: Int
    ) -> NamedLayoutCandidate {
        NamedLayoutCandidate(
            window: WindowMetadata(
                id: WindowID(raw: UInt32(id)),
                bundleID: BundleID(raw: bundleID),
                title: title,
                role: "AXWindow",
                pid: ProcessID(id),
                frame: CGRect(x: x, y: 0, width: 400, height: 600),
                isResizable: true,
                isMinimized: false
            ),
            currentDisplaySlot: displaySlot
        )
    }
}
