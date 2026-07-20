#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

enum ObservationReplayVerification {
    static func verifyPartialTopologyReplay() -> (passed: Bool, message: String) {
        let displayID = DisplayID(raw: 3)
        let spaceFour = SpaceID(raw: 4)
        let spaceThree = SpaceID(raw: 3)
        let spaceFourTile = WindowID(raw: 31639)
        let spaceFourFloating = WindowID(raw: 70013)
        let spaceThreeLeft = WindowID(raw: 77623)
        let spaceThreeRight = WindowID(raw: 75807)
        let spaceThreeUnmappedA = WindowID(raw: 77104)
        let spaceThreeUnmappedB = WindowID(raw: 77375)
        let display = DisplayInfo(
            id: displayID,
            slot: 0,
            fingerprint: "verification-display",
            frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
            visibleFrame: CGRect(x: 0, y: 30, width: 3840, height: 2030)
        )
        let spaceFourState = SpaceState(
            id: spaceFour,
            displays: [
                displayID: DisplaySpaceState(
                    displayID: displayID,
                    tree: pushIntoTree(spaceFourTile, .right, .void),
                    floating: [spaceFourFloating]
                )
            ],
            focused: spaceFourFloating
        )
        let world = World(
            displays: [displayID: display],
            activeSpace: spaceFour,
            activeSpaceByDisplay: [displayID: spaceFour],
            spaces: [
                spaceFour: spaceFourState,
                spaceThree: SpaceState(
                    id: spaceThree,
                    displays: [
                        displayID: DisplaySpaceState(
                            displayID: displayID,
                            tree: pushIntoTree(spaceThreeRight, .right, .void),
                            floating: [spaceThreeLeft]
                        )
                    ],
                    focused: spaceThreeLeft
                )
            ],
            windows: [
                spaceFourTile: metadata(spaceFourTile, x: 1920),
                spaceFourFloating: metadata(spaceFourFloating, x: 200),
                spaceThreeLeft: metadata(spaceThreeLeft, x: 0),
                spaceThreeRight: metadata(spaceThreeRight, x: 1920)
            ],
            windowDisplay: [
                spaceFourTile: displayID,
                spaceFourFloating: displayID,
                spaceThreeLeft: displayID,
                spaceThreeRight: displayID
            ],
            windowSpace: [
                spaceFourTile: spaceFour,
                spaceFourFloating: spaceFour,
                spaceThreeLeft: spaceThree,
                spaceThreeRight: spaceThree
            ],
            windowConstraints: [spaceFourTile: WindowConstraints(minWidth: 500)],
            pendingRules: [spaceFourTile: .forceFloat],
            config: .default
        )
        let observed = [
            metadata(spaceThreeLeft, x: 0),
            metadata(spaceThreeRight, x: 1920),
            metadata(spaceThreeUnmappedA, x: 700),
            metadata(spaceThreeUnmappedB, x: 1100)
        ]
        let snapshot = EnvironmentSnapshot(
            activeSpace: spaceThree,
            displays: [displayID: display],
            axSnapshot: AXWindowSnapshot(windows: observed, quality: .complete),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [displayID: spaceThree],
                windowSpace: [
                    spaceThreeLeft: spaceThree,
                    spaceThreeRight: spaceThree
                ],
                quality: .managedDisplaySpaces
            ),
            reconciliationMode: .observeOnly
        )
        let next: World
        switch apply(.environmentChanged(snapshot), to: world) {
        case .success(let value):
            next = value
        case .failure(let error):
            return (false, "observation replay failed applying environment: \(error.message)")
        }

        let observedKey = WorkspaceKey(displayID: displayID, spaceID: spaceThree)
        guard next.spaces[spaceFour] == spaceFourState else {
            return (false, "observe-only replay changed inactive Space 4 memory")
        }
        guard next.windowSpace[spaceThreeUnmappedA] == nil,
              next.windowSpace[spaceThreeUnmappedB] == nil else {
            return (false, "observation replay assigned durable Space ownership to unmapped windows")
        }
        guard next.observedVisibleWindows[observedKey] == Set(observed.map(\.id)) else {
            return (false, "observation replay did not record visible active-Space windows")
        }
        let cycleCandidates = focusCycleCandidates(
            windows: focusCycleWindows(in: next, focusedWindowID: spaceThreeLeft),
            from: spaceThreeLeft,
            direction: .next
        )
        guard Array(cycleCandidates.prefix(2)) == [
            spaceThreeUnmappedA,
            spaceThreeUnmappedB
        ] else {
            return (false, "observation replay focus cycle did not include visible unmapped untiled windows")
        }
        let replayLayout = Layout(
            tiled: [
                spaceThreeLeft: CGRect(x: 0, y: 30, width: 1920, height: 2030),
                spaceThreeRight: CGRect(x: 1920, y: 30, width: 1920, height: 2030)
            ],
            floatingZOrder: [],
            hidden: []
        )
        guard let leftMetadata = next.windows[spaceThreeLeft],
              let rightMetadata = next.windows[spaceThreeRight],
              let leftFrame = replayLayout.tiled[spaceThreeLeft],
              let rightFrame = replayLayout.tiled[spaceThreeRight] else {
            return (false, "observation replay missing tiled window metadata for production write-order check")
        }
        let replayPlan = CommandPlanResult(
            focusedWindowID: spaceThreeLeft,
            desiredLayout: DesiredLayout(
                generation: LayoutGeneration(raw: 1),
                layout: replayLayout,
                delta: LayoutDelta(moves: replayLayout.tiled, raises: [], hides: [], shows: [])
            ),
            windows: next.windows,
            sourceWorld: next,
            plannedWorld: next,
            undoWorld: nil
        )
        guard layoutFrameWriteIntents(for: replayPlan) == [
            .write(
                windowID: spaceThreeRight,
                metadata: rightMetadata,
                targetFrame: rightFrame
            ),
            .write(
                windowID: spaceThreeLeft,
                metadata: leftMetadata,
                targetFrame: leftFrame
            )
        ] else {
            return (false, "production layout write order no longer keeps an existing focused window last")
        }
        return (
            true,
            "observation replay verified: partial topology preserved inactive memory, visible unmapped windows cycled, production focused writes remain last"
        )
    }

    private static func metadata(_ id: WindowID, x: CGFloat) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example.\(id.raw)"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: CGRect(x: x, y: 30, width: 900, height: 900),
            isResizable: true,
            isMinimized: false
        )
    }
}
#endif
