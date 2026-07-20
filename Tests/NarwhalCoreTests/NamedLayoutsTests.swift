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
