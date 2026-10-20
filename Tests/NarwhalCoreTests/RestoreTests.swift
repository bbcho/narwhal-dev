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

    @Test("storedWorld and restoreWorld keep every Space layout, deferring Spaces that are not visible")
    func storedWorldAndRestoreWorldKeepEveryKnownSpaceLayout() throws {
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
        // At startup only windows on visible Spaces are on screen.
        let restored = restoreWorld(
            from: stored,
            liveWindows: [try #require(world.windows[second])],
            displays: world.displays,
            activeSpace: secondSpace,
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [display: secondSpace],
                windowSpace: [second: secondSpace],
                quality: .managedDisplaySpaces
            ),
            config: .default
        )

        #expect((stored.workspaces ?? []).map(\.spaceID).sorted { $0.raw < $1.raw } == [firstSpace, secondSpace])
        #expect(restored.spaces[firstSpace] == nil)
        #expect(restored.spaces[secondSpace]?.displays[display]?.tree == pushIntoTree(second, .right, .void))
        #expect(restored.windowSpace == [second: secondSpace])
        let deferred = deferredSpaces(in: stored, restoredInto: restored)
        #expect(Array(deferred.keys) == [firstSpace])
        let resaved = storedWorld(from: restored, deferredSpaces: deferred)
        #expect(resaved.workspaces == stored.workspaces)
    }

    @Test("An inactive Space's layout is restored the first time that Space is visible")
    func deferredSpaceRestoresWhenVisible() throws {
        let display = DisplayID(raw: 7)
        let hiddenSpace = SpaceID(raw: 101)
        let visibleSpace = SpaceID(raw: 202)
        let editor = WindowID(raw: 301)
        let editorRef = storedRef(title: "Editor", occurrence: 0, frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: nil,
            workspaces: [
                StoredWorkspace(spaceID: hiddenSpace, space: StoredSpace(
                    layouts: [StoredDisplayLayout(
                        displaySlot: 0,
                        displayFingerprint: "display-7",
                        tree: .split(makeStoredSplit(axis: .horizontal, cells: [
                            makeStoredCell(weight: 1, node: .leaf(editorRef)),
                            makeStoredCell(weight: 1, node: .void)
                        ])),
                        floating: []
                    )],
                    focused: editorRef
                ))
            ],
            pendingRules: []
        )
        let displays = [display: displayInfo(display, slot: 0, x: 0, width: 1200)]
        let atStartup = restoreWorld(
            from: stored,
            liveWindows: [],
            displays: displays,
            activeSpace: visibleSpace,
            config: .default
        )
        let deferred = try #require(deferredSpaces(in: stored, restoredInto: atStartup)[hiddenSpace])
        let visited = World(
            displays: displays,
            activeSpace: hiddenSpace,
            activeSpaceByDisplay: [display: hiddenSpace],
            spaces: [hiddenSpace: SpaceState(
                id: hiddenSpace,
                displays: [display: DisplaySpaceState(displayID: display, tree: .void, floating: [editor])],
                focused: nil
            )],
            windows: [editor: metadata(editor, title: "Editor", frame: CGRect(x: 0, y: 0, width: 600, height: 800))],
            windowDisplay: [editor: display],
            windowSpace: [editor: hiddenSpace],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let restored = try #require(restoringDeferredSpace(deferred, spaceID: hiddenSpace, in: visited))

        #expect(restored.spaces[hiddenSpace]?.displays[display] == DisplaySpaceState(
            displayID: display,
            tree: .split(makeSplit(axis: .horizontal, cells: [
                makeCell(weight: 1, node: .leaf(editor)),
                makeCell(weight: 1, node: .void)
            ])),
            floating: []
        ))
        #expect(restored.spaces[hiddenSpace]?.focused == editor)
    }

    @Test("A Space the user already tiled is not overwritten by its deferred layout")
    func deferredSpaceSkipsAlreadyTiledSpace() throws {
        let display = DisplayID(raw: 7)
        let space = SpaceID(raw: 101)
        let editor = WindowID(raw: 301)
        let other = WindowID(raw: 302)
        let deferred = StoredSpace(
            layouts: [StoredDisplayLayout(
                displaySlot: 0,
                displayFingerprint: "display-7",
                tree: .leaf(storedRef(title: "Editor", occurrence: 0, frame: nil)),
                floating: []
            )],
            focused: nil
        )
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [space: SpaceState(
                id: space,
                displays: [display: DisplaySpaceState(displayID: display, tree: .leaf(other), floating: [editor])],
                focused: other
            )],
            windows: [
                editor: metadata(editor, title: "Editor", frame: CGRect(x: 0, y: 0, width: 600, height: 800)),
                other: metadata(other, title: "Other", frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
            ],
            windowDisplay: [editor: display, other: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        #expect(restoringDeferredSpace(deferred, spaceID: space, in: world) == nil)
    }

    @Test("A deferred Space restores even before reconciliation has created state for it")
    func deferredSpaceRestoresWithoutExistingSpaceState() throws {
        let display = DisplayID(raw: 7)
        let visibleSpace = SpaceID(raw: 202)
        let editor = WindowID(raw: 301)
        let deferred = StoredSpace(
            layouts: [StoredDisplayLayout(
                displaySlot: 0,
                displayFingerprint: "display-7",
                tree: .leaf(storedRef(title: "Editor", occurrence: 0, frame: CGRect(x: 0, y: 0, width: 1200, height: 800))),
                floating: []
            )],
            focused: nil
        )
        let world = World(
            displays: [display: displayInfo(display, slot: 0, x: 0, width: 1200)],
            activeSpace: visibleSpace,
            activeSpaceByDisplay: [display: visibleSpace],
            spaces: [:],
            windows: [editor: metadata(editor, title: "Editor", frame: CGRect(x: 0, y: 0, width: 1200, height: 800))],
            windowDisplay: [editor: display],
            windowSpace: [editor: visibleSpace],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let restored = try #require(restoringDeferredSpace(deferred, spaceID: visibleSpace, in: world))

        #expect(restored.spaces[visibleSpace]?.displays[display] == DisplaySpaceState(
            displayID: display,
            tree: .leaf(editor),
            floating: []
        ))
    }

    @Test("A display matched by fingerprint is never also claimed by another layout's slot fallback")
    func fingerprintMatchIsNotOverwrittenBySlotFallback() throws {
        let space = SpaceID(raw: 1)
        let displayX = DisplayID(raw: 1)
        let displayZ = DisplayID(raw: 3)
        let onX = WindowID(raw: 31)
        let refOnX = storedRef(title: "On X", occurrence: 0, frame: CGRect(x: 1200, y: 0, width: 1200, height: 800))
        let refOnY = storedRef(title: "On Y", occurrence: 0, frame: CGRect(x: 2400, y: 0, width: 1200, height: 800))
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [
                    StoredDisplayLayout(displaySlot: 0, displayFingerprint: "display-1", tree: .leaf(refOnX), floating: []),
                    StoredDisplayLayout(displaySlot: 1, displayFingerprint: "display-2", tree: .leaf(refOnY), floating: [])
                ],
                focused: nil
            ),
            pendingRules: []
        )

        let restored = restoreWorld(
            from: stored,
            liveWindows: [metadata(onX, title: "On X", frame: CGRect(x: 1200, y: 0, width: 1200, height: 800))],
            displays: [
                displayZ: displayInfo(displayZ, slot: 0, x: 0, width: 1200),
                displayX: displayInfo(displayX, slot: 1, x: 1200, width: 1200)
            ],
            activeSpace: space,
            config: .default
        )

        #expect(restored.spaces[space]?.displays[displayX]?.tree == .leaf(onX))
        #expect(restored.spaces[space]?.displays[displayZ]?.tree == .void)
    }

    @Test("Two identical monitors sharing a fingerprint each get their own layout by slot")
    func sharedFingerprintFallsBackToSlot() throws {
        let space = SpaceID(raw: 1)
        let left = DisplayID(raw: 1)
        let right = DisplayID(raw: 2)
        let onLeft = WindowID(raw: 41)
        let onRight = WindowID(raw: 42)
        let refOnLeft = storedRef(title: "Left", occurrence: 0, frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let refOnRight = storedRef(title: "Right", occurrence: 0, frame: CGRect(x: 1200, y: 0, width: 1200, height: 800))
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [
                    StoredDisplayLayout(displaySlot: 0, displayFingerprint: "twin", tree: .leaf(refOnLeft), floating: []),
                    StoredDisplayLayout(displaySlot: 1, displayFingerprint: "twin", tree: .leaf(refOnRight), floating: [])
                ],
                focused: nil
            ),
            pendingRules: []
        )
        let displays = [
            left: DisplayInfo(id: left, slot: 0, fingerprint: "twin",
                              frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)),
            right: DisplayInfo(id: right, slot: 1, fingerprint: "twin",
                               frame: CGRect(x: 1200, y: 0, width: 1200, height: 800),
                               visibleFrame: CGRect(x: 1200, y: 0, width: 1200, height: 800))
        ]

        let restored = restoreWorld(
            from: stored,
            liveWindows: [
                metadata(onLeft, title: "Left", frame: CGRect(x: 0, y: 0, width: 1200, height: 800)),
                metadata(onRight, title: "Right", frame: CGRect(x: 1200, y: 0, width: 1200, height: 800))
            ],
            displays: displays,
            activeSpace: space,
            config: .default
        )

        #expect(restored.spaces[space]?.displays[left]?.tree == .leaf(onLeft))
        #expect(restored.spaces[space]?.displays[right]?.tree == .leaf(onRight))
    }

    @Test("A stored fingerprint shared by several current displays is not an exact match")
    func ambiguousFingerprintFallsBackToSlot() throws {
        let space = SpaceID(raw: 1)
        let solo = DisplayID(raw: 1)
        let window = WindowID(raw: 43)
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [StoredDisplayLayout(
                    displaySlot: 0,
                    displayFingerprint: "twin",
                    tree: .leaf(storedRef(title: "Editor", occurrence: 0, frame: CGRect(x: 0, y: 0, width: 1200, height: 800))),
                    floating: []
                )],
                focused: nil
            ),
            pendingRules: []
        )
        let displays = Dictionary(uniqueKeysWithValues: [(1, "solo"), (2, "twin"), (3, "twin")].map { raw, fingerprint in
            let id = DisplayID(raw: UInt32(raw))
            let frame = CGRect(x: CGFloat(raw - 1) * 1200, y: 0, width: 1200, height: 800)
            return (id, DisplayInfo(id: id, slot: raw - 1, fingerprint: fingerprint, frame: frame, visibleFrame: frame))
        })

        let restored = restoreWorld(
            from: stored,
            liveWindows: [metadata(window, title: "Editor", frame: CGRect(x: 0, y: 0, width: 1200, height: 800))],
            displays: displays,
            activeSpace: space,
            config: .default
        )

        #expect(restored.spaces[space]?.displays[solo]?.tree == .leaf(window))
    }

    @Test("Duplicate-title windows restore by last known frame, not by position in the list")
    func duplicateTitlesRestoreByFrame() throws {
        let display = DisplayID(raw: 7)
        let space = SpaceID(raw: 1)
        let top = CGRect(x: 0, y: 0, width: 1200, height: 266)
        let middle = CGRect(x: 0, y: 266, width: 1200, height: 267)
        let bottom = CGRect(x: 0, y: 533, width: 1200, height: 267)
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [StoredDisplayLayout(
                    displaySlot: 0,
                    displayFingerprint: "display-7",
                    tree: .split(makeStoredSplit(axis: .vertical, cells: [
                        makeStoredCell(weight: 1, node: .leaf(storedRef(title: "zsh", occurrence: 0, frame: top))),
                        makeStoredCell(weight: 1, node: .leaf(storedRef(title: "zsh", occurrence: 1, frame: middle))),
                        makeStoredCell(weight: 1, node: .leaf(storedRef(title: "zsh", occurrence: 2, frame: bottom)))
                    ])),
                    floating: []
                )],
                focused: nil
            ),
            pendingRules: []
        )
        let middleWindow = WindowID(raw: 11)
        let bottomWindow = WindowID(raw: 12)

        let restored = restoreWorld(
            from: stored,
            liveWindows: [
                metadata(middleWindow, title: "zsh", frame: middle),
                metadata(bottomWindow, title: "zsh", frame: bottom)
            ],
            displays: [display: displayInfo(display, slot: 0, x: 0, width: 1200)],
            activeSpace: space,
            config: .default
        )

        #expect(restored.spaces[space]?.displays[display]?.tree == .split(makeSplit(axis: .vertical, cells: [
            makeCell(weight: 1, node: .void),
            makeCell(weight: 1, node: .leaf(middleWindow)),
            makeCell(weight: 1, node: .leaf(bottomWindow))
        ])))
    }

    @Test("Windows that were not in the saved state get open rules and managed minimum sizes at startup")
    func newWindowsGetRulesAtStartup() throws {
        let display = DisplayID(raw: 7)
        let space = SpaceID(raw: 1)
        let saved = WindowID(raw: 21)
        let ignored = WindowID(raw: 22)
        let config = Config(
            keymap: Config.default.keymap,
            rules: [WindowRule(predicate: .bundleID("com.example.ignored"), action: .ignore)],
            zones: Config.default.zones,
            gaps: Config.default.gaps,
            border: Config.default.border,
            hud: Config.default.hud,
            dragModifier: Config.default.dragModifier,
            managedRules: [ManagedWindowRule(
                id: ManagedRuleID(rawValue: "wide"),
                name: "Wide",
                matcher: ManagedRuleMatcher(bundleID: "com.example"),
                policy: ManagedRulePolicy(minimumWidth: 500)
            )]
        )
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [StoredDisplayLayout(
                    displaySlot: 0,
                    displayFingerprint: "display-7",
                    tree: .leaf(storedRef(title: "Saved", occurrence: 0, frame: CGRect(x: 0, y: 0, width: 1200, height: 800))),
                    floating: []
                )],
                focused: nil
            ),
            pendingRules: []
        )
        let ignoredWindow = WindowMetadata(
            id: ignored,
            bundleID: BundleID(raw: "com.example.ignored"),
            title: "Ignored",
            role: "AXWindow",
            pid: 43,
            frame: CGRect(x: 100, y: 100, width: 300, height: 300),
            isResizable: true,
            isMinimized: false
        )

        let restored = restoreWorld(
            from: stored,
            liveWindows: [
                metadata(saved, title: "Saved", frame: CGRect(x: 0, y: 0, width: 1200, height: 800)),
                ignoredWindow
            ],
            displays: [display: displayInfo(display, slot: 0, x: 0, width: 1200)],
            activeSpace: space,
            config: config
        )

        #expect(restored.windows[ignored] == nil)
        #expect(restored.spaces[space]?.displays[display]?.tree == .leaf(saved))
        #expect(effectiveWindowConstraints(in: restored) == [saved: WindowConstraints(minWidth: 500)])
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
