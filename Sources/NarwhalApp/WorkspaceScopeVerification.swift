import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

enum WorkspaceScopeVerification {
    static func verifyFocusedCommandsStayOnOneDisplay() -> (passed: Bool, message: String) {
        let leftDisplay = DisplayID(raw: 101)
        let rightDisplay = DisplayID(raw: 102)
        let space = SpaceID(raw: 201)
        let leftTiled = window(1, frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let leftFloating = window(2, frame: CGRect(x: 200, y: 0, width: 400, height: 800))
        let rightTiled = window(3, frame: CGRect(x: 1200, y: 0, width: 400, height: 800))
        let world = world(
            displays: [
                leftDisplay: DisplaySpaceState(displayID: leftDisplay, tree: .leaf(leftTiled.id), floating: [leftFloating.id]),
                rightDisplay: DisplaySpaceState(displayID: rightDisplay, tree: .leaf(rightTiled.id), floating: [])
            ],
            windows: [leftTiled, leftFloating, rightTiled],
            windowDisplay: [
                leftTiled.id: leftDisplay,
                leftFloating.id: leftDisplay,
                rightTiled.id: rightDisplay
            ],
            activeSpace: space,
            focused: leftFloating.id
        )

        guard case .success(let pushedWorld) = apply(.push(leftFloating.id, .right), to: world) else {
            return (false, "workspace scope verification failed: push planning command was rejected")
        }
        let scope = commandPlanScope(
            focusedWindowID: leftFloating.id,
            oldWorld: world,
            newWorld: pushedWorld
        )
        guard scope == .workspace(WorkspaceKey(displayID: leftDisplay, spaceID: space)) else {
            return (false, "workspace scope verification failed: focused push scope was \(scope)")
        }
        guard case .success(let plan) = commandPlan(
            from: world,
            to: pushedWorld,
            focusedWindowID: leftFloating.id,
            undoWorld: world,
            generation: LayoutGeneration(raw: 1),
            scope: scope
        ) else {
            return (false, "workspace scope verification failed: scoped command plan was rejected")
        }
        guard Set(plan.desiredLayout.layout.tiled.keys) == [leftTiled.id, leftFloating.id],
              plan.desiredLayout.layout.tiled[rightTiled.id] == nil else {
            return (
                false,
                "workspace scope verification failed: scoped plan included wrong windows \(plan.desiredLayout.layout.tiled.keys.map(\.description).sorted())"
            )
        }
        switch focusDirectionPlan(in: world, from: leftTiled.id, direction: .right) {
        case .success(let focusPlan) where focusPlan.window.id == rightTiled.id:
            return (false, "workspace scope verification failed: focus right crossed into another display")
        case .success, .failure(.noNeighbor):
            break
        case .failure(let error):
            return (false, "workspace scope verification failed: focus right returned unexpected error \(error.message)")
        }
        guard apply(.swapInTree(leftTiled.id, .right), to: world) == .failure(.noNeighbor(.right)) else {
            return (false, "workspace scope verification failed: swap right crossed into another display")
        }

        let activeSpaces = [
            leftDisplay: space,
            rightDisplay: SpaceID(raw: 202)
        ]
        let inventoryBaseline = windowInventoryObservationBaseline(
            windows: [leftTiled, rightTiled],
            activeSpaceByDisplay: activeSpaces
        )
        let inventoryTransition = observeWindowInventory(
            windows: [leftTiled, rightTiled],
            activeSpaceByDisplay: activeSpaces,
            tolerance: 1,
            in: inventoryBaseline
        )
        guard inventoryTransition.effect == nil else {
            return (false, "workspace scope verification failed: focused-display notification reset inventory")
        }

        return (
            true,
            "workspace scope verified: focused push writes left display only; focus and swap reject cross-display neighbors; focused-display notifications preserve inventory"
        )
    }

    private static func world(
        displays: [DisplayID: DisplaySpaceState],
        windows: [WindowMetadata],
        windowDisplay: [WindowID: DisplayID],
        activeSpace: SpaceID,
        focused: WindowID?
    ) -> World {
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let windowSpace = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, activeSpace) })
        let displayInfos = Dictionary(uniqueKeysWithValues: displays.keys.map { displayID in
            let slot = displayID.raw == 101 ? 0 : 1
            let x = CGFloat(slot) * 1000
            return (
                displayID,
                DisplayInfo(
                    id: displayID,
                    slot: slot,
                    fingerprint: "verify-\(displayID.raw)",
                    frame: CGRect(x: x, y: 0, width: 1000, height: 800),
                    visibleFrame: CGRect(x: x, y: 0, width: 1000, height: 800)
                )
            )
        })
        let observed = Dictionary(uniqueKeysWithValues: displays.keys.map { displayID in
            (
                WorkspaceKey(displayID: displayID, spaceID: activeSpace),
                Set(windowDisplay.compactMap { $0.value == displayID ? $0.key : nil })
            )
        })

        return World(
            displays: displayInfos,
            activeSpace: activeSpace,
            activeSpaceByDisplay: Dictionary(uniqueKeysWithValues: displays.keys.map { ($0, activeSpace) }),
            spaces: [
                activeSpace: SpaceState(id: activeSpace, displays: displays, focused: focused)
            ],
            windows: windowsByID,
            windowDisplay: windowDisplay,
            windowSpace: windowSpace,
            observedVisibleWindows: observed,
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private static func window(_ raw: UInt32, frame: CGRect) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: raw),
            bundleID: BundleID(raw: "com.example.verify.\(raw)"),
            title: "Verify \(raw)",
            role: "AXWindow",
            pid: ProcessID(raw),
            frame: frame,
            isResizable: true,
            isMinimized: false
        )
    }
}
