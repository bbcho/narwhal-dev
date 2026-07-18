import CoreGraphics
import Foundation
import Testing
@testable import NarwhalCore

@Suite("Restore projection and remap")
struct RestoreTests {
    @Test("storedWorld projects the active Space tree to stable duplicate-aware refs")
    func storedWorldProjectsActiveSpaceTree() throws {
        let display = DisplayID(raw: 10)
        let space = SpaceID(raw: 20)
        let first = WindowID(raw: 101)
        let second = WindowID(raw: 102)
        let tree = pushIntoTree(second, .right, pushIntoTree(first, .left, .void))
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
                    focused: second
                )
            ],
            windows: [
                first: metadata(first, title: "Same", frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
                second: metadata(second, title: "Same", frame: CGRect(x: 500, y: 0, width: 400, height: 300))
            ],
            windowDisplay: [first: display, second: display],
            windowConstraints: [:],
            pendingRules: [second: .pinToDisplay(slot: 0)],
            config: .default
        )

        let stored = storedWorld(from: world)
        let firstRef = StoredWindowRef(
            bundleID: BundleID(raw: "com.example"),
            title: "Same",
            role: "AXWindow",
            occurrence: 0,
            lastKnownFrame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let secondRef = StoredWindowRef(
            bundleID: BundleID(raw: "com.example"),
            title: "Same",
            role: "AXWindow",
            occurrence: 1,
            lastKnownFrame: CGRect(x: 500, y: 0, width: 400, height: 300)
        )
        let expectedTree = StoredNode.split(makeStoredSplit(axis: .horizontal, cells: [
            makeStoredCell(weight: 1, node: .leaf(firstRef)),
            makeStoredCell(weight: 1, node: .leaf(secondRef))
        ]))

        #expect(stored.schemaVersion == StoredWorld.currentSchemaVersion)
        #expect(stored.activeSpace?.layouts == [
            StoredDisplayLayout(displaySlot: 0, displayFingerprint: "display-10", tree: expectedTree, floating: [])
        ])
        #expect(stored.activeSpace?.focused == secondRef)
        #expect(stored.pendingRules == [
            StoredPendingRule(window: secondRef, action: .pinToDisplay(displaySlot: 0))
        ])
    }

    @Test("restoreWorld maps stored refs to current live WindowIDs by occurrence and display slot")
    func restoreWorldMapsStoredRefsToLiveWindows() throws {
        let activeSpace = SpaceID(raw: 55)
        let display = DisplayID(raw: 77)
        let firstRef = storedRef(title: "Same", occurrence: 0, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let secondRef = storedRef(title: "Same", occurrence: 1, frame: CGRect(x: 500, y: 0, width: 400, height: 300))
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [
                    StoredDisplayLayout(
                        displaySlot: 0,
                        displayFingerprint: nil,
                        tree: .split(makeStoredSplit(axis: .horizontal, cells: [
                            makeStoredCell(weight: 1, node: .leaf(firstRef)),
                            makeStoredCell(weight: 1, node: .leaf(secondRef))
                        ])),
                        floating: []
                    )
                ],
                focused: secondRef
            ),
            pendingRules: [StoredPendingRule(window: firstRef, action: .forceFloat)]
        )
        let liveFirst = WindowID(raw: 901)
        let liveSecond = WindowID(raw: 902)
        let liveFloating = WindowID(raw: 903)

        let world = restoreWorld(
            from: stored,
            liveWindows: [
                metadata(liveSecond, title: "Same", frame: CGRect(x: 500, y: 0, width: 400, height: 300)),
                metadata(liveFloating, title: "Other", frame: CGRect(x: 900, y: 0, width: 200, height: 200)),
                metadata(liveFirst, title: "Same", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            ],
            displays: [display: displayInfo(display, slot: 0, x: 0, width: 1200)],
            activeSpace: activeSpace,
            config: .default
        )

        let displayState = world.spaces[activeSpace]?.displays[display]
        #expect(world.activeSpace == activeSpace)
        #expect(displayState?.tree == .split(makeSplit(axis: .horizontal, cells: [
            makeCell(weight: 1, node: .leaf(liveFirst)),
            makeCell(weight: 1, node: .leaf(liveSecond))
        ])))
        #expect(displayState?.floating == [liveFloating])
        #expect(world.spaces[activeSpace]?.focused == liveSecond)
        #expect(world.windowDisplay == [liveFirst: display, liveSecond: display, liveFloating: display])
        #expect(world.pendingRules == [liveFirst: .forceFloat])
    }

    @Test("restoreWorld uses duplicate occurrence indexes without requiring last known frames")
    func restoreWorldUsesDuplicateOccurrenceWithoutFrames() throws {
        let activeSpace = SpaceID(raw: 88)
        let display = DisplayID(raw: 99)
        let firstRef = storedRef(title: "Same", occurrence: 0, frame: nil)
        let secondRef = storedRef(title: "Same", occurrence: 1, frame: nil)
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [
                    StoredDisplayLayout(
                        displaySlot: 0,
                        displayFingerprint: nil,
                        tree: .split(makeStoredSplit(axis: .horizontal, cells: [
                            makeStoredCell(weight: 1, node: .leaf(firstRef)),
                            makeStoredCell(weight: 1, node: .leaf(secondRef))
                        ])),
                        floating: []
                    )
                ],
                focused: nil
            ),
            pendingRules: []
        )
        let liveFirst = WindowID(raw: 51)
        let liveSecond = WindowID(raw: 52)

        let world = restoreWorld(
            from: stored,
            liveWindows: [
                metadata(liveSecond, title: "Same", frame: CGRect(x: 500, y: 0, width: 400, height: 300)),
                metadata(liveFirst, title: "Same", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            ],
            displays: [display: displayInfo(display, slot: 0, x: 0, width: 1200)],
            activeSpace: activeSpace,
            config: .default
        )

        #expect(world.spaces[activeSpace]?.displays[display]?.tree == .split(makeSplit(axis: .horizontal, cells: [
            makeCell(weight: 1, node: .leaf(liveFirst)),
            makeCell(weight: 1, node: .leaf(liveSecond))
        ])))
    }

    @Test("restoreWorld matches changed titles by application, role, and nearest frame")
    func restoreWorldMatchesChangedTitlesByNearestFrame() throws {
        let activeSpace = SpaceID(raw: 89)
        let display = DisplayID(raw: 90)
        let leftRef = storedRef(title: "Draft — yesterday", occurrence: 0, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let rightRef = storedRef(title: "Notes — yesterday", occurrence: 0, frame: CGRect(x: 500, y: 0, width: 400, height: 300))
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [StoredDisplayLayout(
                    displaySlot: 0,
                    displayFingerprint: nil,
                    tree: .split(makeStoredSplit(axis: .horizontal, cells: [
                        makeStoredCell(weight: 1, node: .leaf(leftRef)),
                        makeStoredCell(weight: 1, node: .leaf(rightRef))
                    ])),
                    floating: []
                )],
                focused: rightRef
            ),
            pendingRules: []
        )
        let left = WindowID(raw: 61)
        let right = WindowID(raw: 62)

        let world = restoreWorld(
            from: stored,
            liveWindows: [
                metadata(right, title: "Notes — today", frame: CGRect(x: 500, y: 0, width: 400, height: 300)),
                metadata(left, title: "Draft — today", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            ],
            displays: [display: displayInfo(display, slot: 0, x: 0, width: 1200)],
            activeSpace: activeSpace,
            config: .default
        )

        #expect(world.spaces[activeSpace]?.displays[display]?.tree == .split(makeSplit(axis: .horizontal, cells: [
            makeCell(weight: 1, node: .leaf(left)),
            makeCell(weight: 1, node: .leaf(right))
        ])))
        #expect(world.spaces[activeSpace]?.focused == right)
    }

    @Test("restoreWorld does not fuzzy-match title changes without a last known frame")
    func restoreWorldDoesNotFuzzyMatchWithoutFrame() throws {
        let activeSpace = SpaceID(raw: 91)
        let display = DisplayID(raw: 92)
        let ref = storedRef(title: "Old title", occurrence: 0, frame: nil)
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [StoredDisplayLayout(
                    displaySlot: 0,
                    displayFingerprint: nil,
                    tree: .leaf(ref),
                    floating: []
                )],
                focused: ref
            ),
            pendingRules: []
        )
        let live = WindowID(raw: 63)

        let world = restoreWorld(
            from: stored,
            liveWindows: [metadata(live, title: "New title", frame: CGRect(x: 0, y: 0, width: 400, height: 300))],
            displays: [display: displayInfo(display, slot: 0, x: 0, width: 1200)],
            activeSpace: activeSpace,
            config: .default
        )

        #expect(world.spaces[activeSpace]?.displays[display]?.tree == .void)
        #expect(world.spaces[activeSpace]?.focused == nil)
    }

    @Test("restoreWorld drops unmatched leaves while preserving stored split shape")
    func restoreWorldDropsUnmatchedLeavesPreservingShape() throws {
        let activeSpace = SpaceID(raw: 3)
        let display = DisplayID(raw: 4)
        let matchedRef = storedRef(title: "Matched", occurrence: 0, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let missingRef = storedRef(title: "Missing", occurrence: 0, frame: CGRect(x: 500, y: 0, width: 400, height: 300))
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [
                    StoredDisplayLayout(
                        displaySlot: 0,
                        displayFingerprint: nil,
                        tree: .split(makeStoredSplit(axis: .horizontal, cells: [
                            makeStoredCell(weight: 1, node: .leaf(matchedRef)),
                            makeStoredCell(weight: 1, node: .leaf(missingRef))
                        ])),
                        floating: []
                    )
                ],
                focused: missingRef
            ),
            pendingRules: []
        )
        let liveMatched = WindowID(raw: 11)

        let world = restoreWorld(
            from: stored,
            liveWindows: [metadata(liveMatched, title: "Matched", frame: CGRect(x: 0, y: 0, width: 400, height: 300))],
            displays: [display: displayInfo(display, slot: 0, x: 0, width: 1200)],
            activeSpace: activeSpace,
            config: .default
        )

        #expect(world.spaces[activeSpace]?.displays[display]?.tree == .split(makeSplit(axis: .horizontal, cells: [
            makeCell(weight: 1, node: .leaf(liveMatched)),
            makeCell(weight: 1, node: .void)
        ])))
        #expect(world.spaces[activeSpace]?.focused == nil)
    }

    @Test("storedWorld and restoreWorld preserve every known Space layout")
    func storedWorldAndRestoreWorldPreserveEveryKnownSpaceLayout() throws {
        let display = DisplayID(raw: 7)
        let firstSpace = SpaceID(raw: 101)
        let secondSpace = SpaceID(raw: 202)
        let first = WindowID(raw: 301)
        let second = WindowID(raw: 302)
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0, width: 1200)],
            activeSpace: secondSpace,
            activeSpaceByDisplay: [display: secondSpace],
            spaces: [
                firstSpace: SpaceState(
                    id: firstSpace,
                    displays: [
                        display: DisplaySpaceState(
                            displayID: display,
                            tree: pushIntoTree(first, .left, .void),
                            floating: []
                        )
                    ],
                    focused: first
                ),
                secondSpace: SpaceState(
                    id: secondSpace,
                    displays: [
                        display: DisplaySpaceState(
                            displayID: display,
                            tree: pushIntoTree(second, .right, .void),
                            floating: []
                        )
                    ],
                    focused: second
                )
            ],
            windows: [
                first: metadata(first, title: "First", frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
                second: metadata(second, title: "Second", frame: CGRect(x: 500, y: 0, width: 400, height: 300))
            ],
            windowDisplay: [first: display, second: display],
            windowSpace: [first: firstSpace, second: secondSpace],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let stored = storedWorld(from: world)
        let restored = restoreWorld(
            from: stored,
            liveWindows: Array(world.windows.values),
            displays: world.displays,
            activeSpace: secondSpace,
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [display: secondSpace],
                windowSpace: [first: firstSpace, second: secondSpace],
                quality: .managedDisplaySpaces
            ),
            config: .default
        )

        #expect((stored.workspaces ?? []).map(\.spaceID).sorted { $0.raw < $1.raw } == [firstSpace, secondSpace])
        #expect(restored.spaces[firstSpace]?.displays[display]?.tree == pushIntoTree(first, .left, .void))
        #expect(restored.spaces[secondSpace]?.displays[display]?.tree == pushIntoTree(second, .right, .void))
        #expect(restored.windowSpace == [first: firstSpace, second: secondSpace])
    }

    @Test("StoredWorld JSON round-trips exactly")
    func storedWorldJSONRoundTripsExactly() throws {
        let ref = storedRef(title: "Window", occurrence: 0, frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [
                    StoredDisplayLayout(
                        displaySlot: 0,
                        displayFingerprint: "main",
                        tree: .leaf(ref),
                        floating: [ref]
                    )
                ],
                focused: ref
            ),
            pendingRules: [StoredPendingRule(window: ref, action: .ignore)]
        )

        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredWorld.self, from: data)

        #expect(decoded == stored)
    }

    private func storedRef(title: String, occurrence: Int, frame: CGRect?) -> StoredWindowRef {
        StoredWindowRef(
            bundleID: BundleID(raw: "com.example"),
            title: title,
            role: "AXWindow",
            occurrence: occurrence,
            lastKnownFrame: frame
        )
    }

    private func metadata(_ id: WindowID, title: String, frame: CGRect) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example"),
            title: title,
            role: "AXWindow",
            pid: 42,
            frame: frame,
            isResizable: true,
            isMinimized: false
        )
    }

    private func displayInfo(_ id: DisplayID, slot: Int, x: Double, width: Double) -> DisplayInfo {
        DisplayInfo(
            id: id,
            slot: slot,
            fingerprint: "display-\(id.raw)",
            frame: CGRect(x: x, y: 0, width: width, height: 800),
            visibleFrame: CGRect(x: x, y: 0, width: width, height: 800)
        )
    }

    private func makeStoredCell(weight: Double, node: StoredNode) -> StoredCell {
        switch StoredCell.create(weight: weight, node: node) {
        case .success(let cell):
            return cell
        case .failure(let error):
            preconditionFailure("Unexpected invalid StoredCell: \(error)")
        }
    }

    private func makeStoredSplit(axis: Axis, cells: [StoredCell]) -> StoredSplit {
        switch StoredSplit.create(axis: axis, cells: cells) {
        case .success(let split):
            return split
        case .failure(let error):
            preconditionFailure("Unexpected invalid StoredSplit: \(error)")
        }
    }

    private func makeCell(weight: Double, node: Node) -> Cell {
        switch Cell.create(weight: weight, node: node) {
        case .success(let cell):
            return cell
        case .failure(let error):
            preconditionFailure("Unexpected invalid Cell: \(error)")
        }
    }

    private func makeSplit(axis: Axis, cells: [Cell]) -> Split {
        switch Split.create(axis: axis, cells: cells) {
        case .success(let split):
            return split
        case .failure(let error):
            preconditionFailure("Unexpected invalid Split: \(error)")
        }
    }
}
