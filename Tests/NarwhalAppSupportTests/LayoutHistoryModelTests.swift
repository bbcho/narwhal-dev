import CoreGraphics
import NarwhalAppSupport
import NarwhalCore
import Testing

@Suite("Layout history")
struct LayoutHistoryModelTests {
    private let spaceA = SpaceID(raw: 1)
    private let spaceB = SpaceID(raw: 2)
    private let displayA = DisplayID(raw: 10)
    private let displayB = DisplayID(raw: 20)

    @Test("History is bounded independently per Space and a new edit clears redo")
    func boundedPerSpaceHistory() {
        let entriesA = (1...4).map { entry(label: "A\($0)", spaceID: spaceA, windowID: WindowID(raw: UInt32($0))) }
        let entryB = entry(label: "B", spaceID: spaceB, windowID: WindowID(raw: 20))
        var state = LayoutHistoryState(limit: 3)
        for value in entriesA {
            state = layoutHistoryByRecording(value, in: state)
        }
        state = layoutHistoryByRecording(entryB, in: state)

        #expect(state.spaces[spaceA]?.undo.map(\.label) == ["A2", "A3", "A4"])
        #expect(state.spaces[spaceB]?.undo.map(\.label) == ["B"])

        state = layoutHistoryByCommittingUndo(for: spaceA, in: state)
        #expect(state.spaces[spaceA]?.redo.map(\.label) == ["A4"])
        state = layoutHistoryByRecording(entry(label: "A5", spaceID: spaceA, windowID: WindowID(raw: 5)), in: state)
        #expect(state.spaces[spaceA]?.undo.map(\.label) == ["A2", "A3", "A5"])
        #expect(state.spaces[spaceA]?.redo.isEmpty == true)
        #expect(state.spaces[spaceB]?.undo.map(\.label) == ["B"])
    }

    @Test("Undo and redo transition only after an explicit commit")
    func undoRedoCommitProtocol() throws {
        let value = entry(label: "Push", spaceID: spaceA, windowID: WindowID(raw: 1))
        let recorded = layoutHistoryByRecording(value, in: .empty)

        #expect(layoutHistoryUndoEntry(for: spaceA, in: recorded) == value)
        #expect(layoutHistoryUndoEntry(for: spaceA, in: recorded) == value)

        let undone = layoutHistoryByCommittingUndo(for: spaceA, in: recorded)
        #expect(undone.spaces[spaceA]?.undo.isEmpty == true)
        #expect(layoutHistoryRedoEntry(for: spaceA, in: undone) == value)

        let redone = layoutHistoryByCommittingRedo(for: spaceA, in: undone)
        #expect(redone.spaces[spaceA]?.undo == [value])
        #expect(redone.spaces[spaceA]?.redo.isEmpty == true)
    }

    @Test("Restoring one Space does not rewind another Space")
    func spaceRestoreIsIsolated() {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let before = world(
            spaceATree: .leaf(a),
            spaceBTree: .leaf(b),
            windows: [a, b],
            displayForA: displayA
        )
        let current = world(
            spaceATree: .void,
            spaceBTree: .leaf(b),
            windows: [a, b],
            displayForA: displayB
        )

        let restored = worldByRestoringHistorySpace(from: before, spaceID: spaceA, onto: current)

        #expect(restored.spaces[spaceA]?.displays[displayA]?.tree == .leaf(a))
        #expect(restored.spaces[spaceB] == current.spaces[spaceB])
        #expect(restored.windowDisplay[a] == displayA)
        #expect(restored.windowDisplay[b] == current.windowDisplay[b])
        #expect(restored.config == current.config)
    }

    @Test("Historical layout replaces only the target Space frames")
    func layoutRestoreIsIsolated() {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let historicalWorld = world(spaceATree: .leaf(a), spaceBTree: .leaf(b), windows: [a, b], displayForA: displayA)
        let currentWorld = world(spaceATree: .leaf(a), spaceBTree: .leaf(b), windows: [a, b], displayForA: displayA)
        let historicalA = CGRect(x: 0, y: 0, width: 400, height: 800)
        let currentA = CGRect(x: 0, y: 0, width: 600, height: 800)
        let currentB = CGRect(x: 1_000, y: 0, width: 800, height: 800)
        let result = layoutByRestoringHistorySpace(
            Layout(tiled: [a: historicalA], floatingZOrder: [], hidden: []),
            historicalWorld: historicalWorld,
            spaceID: spaceA,
            currentLayout: Layout(tiled: [a: currentA, b: currentB], floatingZOrder: [], hidden: []),
            currentWorld: currentWorld
        )

        #expect(result.tiled == [a: historicalA, b: currentB])
    }

    @Test("Closing a referenced window prunes invalid undo and redo entries")
    func pruneClosedWindows() {
        let kept = entry(label: "Kept", spaceID: spaceA, windowID: WindowID(raw: 1))
        let closed = entry(label: "Closed", spaceID: spaceA, windowID: WindowID(raw: 2))
        let state = LayoutHistoryState(spaces: [
            spaceA: SpaceLayoutHistory(undo: [kept, closed], redo: [closed])
        ])

        let pruned = prunedLayoutHistoryState(liveWindowIDs: [WindowID(raw: 1)], in: state)

        #expect(pruned.spaces[spaceA]?.undo == [kept])
        #expect(pruned.spaces[spaceA]?.redo.isEmpty == true)
    }

    private func entry(label: String, spaceID: SpaceID, windowID: WindowID) -> LayoutHistoryEntry {
        let value = world(
            spaceATree: spaceID == spaceA ? .leaf(windowID) : .void,
            spaceBTree: spaceID == spaceB ? .leaf(windowID) : .void,
            windows: [windowID],
            displayForA: displayA
        )
        let frame = value.windows[windowID]?.frame ?? .zero
        let layout = Layout(tiled: [windowID: frame], floatingZOrder: [], hidden: [])
        return LayoutHistoryEntry(
            label: label,
            spaceID: spaceID,
            beforeWorld: value,
            afterWorld: value,
            beforeLayout: layout,
            afterLayout: layout
        )
    }

    private func world(
        spaceATree: Node,
        spaceBTree: Node,
        windows: [WindowID],
        displayForA: DisplayID
    ) -> World {
        let displays = [
            displayA: display(displayA, x: 0),
            displayB: display(displayB, x: 1_000)
        ]
        let metadata = Dictionary(uniqueKeysWithValues: windows.map { id in
            (id, WindowMetadata(
                id: id,
                bundleID: BundleID(raw: "com.example.\(id.raw)"),
                title: "Window \(id.raw)",
                role: "AXWindow",
                pid: ProcessID(id.raw),
                frame: CGRect(x: id == WindowID(raw: 1) ? 0 : 1_000, y: 0, width: 500, height: 800),
                isResizable: true,
                isMinimized: false
            ))
        })
        return World(
            displays: displays,
            activeSpace: spaceA,
            activeSpaceByDisplay: [displayA: spaceA, displayB: spaceB],
            spaces: [
                spaceA: SpaceState(
                    id: spaceA,
                    displays: [displayForA: DisplaySpaceState(displayID: displayForA, tree: spaceATree, floating: [])],
                    focused: nil
                ),
                spaceB: SpaceState(
                    id: spaceB,
                    displays: [displayB: DisplaySpaceState(displayID: displayB, tree: spaceBTree, floating: [])],
                    focused: nil
                )
            ],
            windows: metadata,
            windowDisplay: Dictionary(uniqueKeysWithValues: windows.map { id in
                (id, id == WindowID(raw: 1) ? displayForA : displayB)
            }),
            windowSpace: Dictionary(uniqueKeysWithValues: windows.map { id in
                (id, id == WindowID(raw: 1) ? spaceA : spaceB)
            }),
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private func display(_ id: DisplayID, x: CGFloat) -> DisplayInfo {
        DisplayInfo(
            id: id,
            slot: id == displayA ? 0 : 1,
            fingerprint: nil,
            frame: CGRect(x: x, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: x, y: 0, width: 1_000, height: 800)
        )
    }
}
