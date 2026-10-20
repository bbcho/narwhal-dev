import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

/// Drives seeded random sequences of layout commands, external focus, moves
/// and resizes, and window arrivals and departures (as `.environmentChanged`
/// snapshots, whose `apply` arm calls the `reconcileEnvironment` production
/// uses), recording solved frames the way `WorldActor.commit` does, and checks
/// the world after every step. Zone drops and config reloads are not generated.
@Suite("Mixed command sequences")
struct MixedCommandSequenceTests {
    private let space = SpaceID(raw: 1)
    private let displays = [
        DisplayID(raw: 1): DisplayInfo(
            id: DisplayID(raw: 1),
            slot: 0,
            fingerprint: "left",
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 760)
        ),
        DisplayID(raw: 2): DisplayInfo(
            id: DisplayID(raw: 2),
            slot: 1,
            fingerprint: "right",
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 760)
        ),
    ]

    @Test("Seeded command sequences keep every window tracked once and every layout disjoint and on screen")
    func seededSequencesKeepInvariants() throws {
        seeds: for seed in UInt64(1)...25 {
            var generator = SeededGenerator(seed: seed)
            var nextWindowRaw = CGWindowID(7)
            var world = try environmentChanged(
                windows: (1...6).map { window(WindowID(raw: $0), onDisplayAt: $0 % 2 == 0 ? 1000 : 0) },
                in: emptyWorld()
            )

            for step in 0..<80 {
                let step = randomStep(in: world, nextWindowRaw: &nextWindowRaw, using: &generator)
                let note = "seed \(seed) \(step)"
                switch apply(step, to: world) {
                case .success(let next):
                    world = worldByRecordingWindowFrames(solvedFrames(in: next), in: next)
                case .failure(let error):
                    if isExpectedRejection(error, of: step) { continue }
                    Issue.record("Unexpected rejection in \(note): \(error.message)")
                    continue seeds
                }
                if !holdsInvariants(world, note: note) { continue seeds }
            }
        }
    }

    // MARK: - Steps

    private func randomStep(
        in world: World,
        nextWindowRaw: inout CGWindowID,
        using generator: inout SeededGenerator
    ) -> Command {
        let windowIDs = world.windows.keys.sorted { $0.raw < $1.raw }
        guard let windowID = windowIDs.randomElement(using: &generator) else {
            return openedWindow(in: world, nextWindowRaw: &nextWindowRaw, using: &generator)
        }
        let direction = Direction.allCases.randomElement(using: &generator)!
        switch Int.random(in: 0..<14, using: &generator) {
        case 0: return .push(windowID, direction)
        case 1: return .center(windowID)
        case 2: return .eject(windowID)
        case 3: return .swapInTree(windowID, direction)
        case 4: return .resizeSplit(windowID, direction, delta: Bool.random(using: &generator) ? 0.10 : -0.10)
        case 5: return .toggleFloat(windowID)
        case 6: return .moveToNextDisplay(windowID)
        case 7: return .windowFocusedExternally(windowID)
        case 8: return .balance(space)
        case 9: return closedWindow(windowID, in: world)
        case 10:
            let origin = CGPoint(
                x: Double.random(in: 0..<1_800, using: &generator).rounded(),
                y: Double.random(in: 0..<600, using: &generator).rounded()
            )
            return .windowMovedExternally(windowID, CGRect(origin: origin, size: CGSize(width: 360, height: 240)))
        case 11:
            let size = CGSize(
                width: Double.random(in: 100..<1_200, using: &generator).rounded(),
                height: Double.random(in: 100..<700, using: &generator).rounded()
            )
            return .windowResizedExternally(windowID, size)
        default: return openedWindow(in: world, nextWindowRaw: &nextWindowRaw, using: &generator)
        }
    }

    private func openedWindow(
        in world: World,
        nextWindowRaw: inout CGWindowID,
        using generator: inout SeededGenerator
    ) -> Command {
        let opened = window(WindowID(raw: nextWindowRaw), onDisplayAt: Bool.random(using: &generator) ? 0 : 1000)
        nextWindowRaw += 1
        return .environmentChanged(snapshot(windows: Array(world.windows.values) + [opened]))
    }

    private func closedWindow(_ windowID: WindowID, in world: World) -> Command {
        .environmentChanged(snapshot(windows: world.windows.values.filter { $0.id != windowID }))
    }

    /// Only swaps and resizes can be refused in an arbitrary layout, and only
    /// for these reasons. Any other rejection, including from a command
    /// that should always succeed, is a bug.
    private func isExpectedRejection(_ error: CommandError, of command: Command) -> Bool {
        switch (command, error) {
        case (.swapInTree, .noNeighbor), (.swapInTree, .windowIsFloating),
             (.resizeSplit, .noNeighbor), (.resizeSplit, .windowIsFloating),
             (.resizeSplit, .resizeWouldCollapseSplit):
            return true
        default:
            return false
        }
    }

    // MARK: - Invariants

    /// Records an issue and returns false at the first broken invariant.
    private func holdsInvariants(_ world: World, note: String) -> Bool {
        var tracked: [WindowID: WorkspaceKey] = [:]
        for (spaceID, spaceState) in world.spaces {
            for (displayID, displayState) in spaceState.displays {
                let key = WorkspaceKey(displayID: displayID, spaceID: spaceID)
                for windowID in occupiedWindows(in: displayState.tree) + displayState.floating {
                    guard tracked[windowID] == nil else {
                        Issue.record("\(windowID) is tracked twice in \(note)")
                        return false
                    }
                    tracked[windowID] = key
                }
            }
            if let focused = spaceState.focused, world.windows[focused] == nil {
                Issue.record("Focused \(focused) is not a known window in \(note)")
                return false
            }
        }
        guard Set(tracked.keys) == Set(world.windows.keys) else {
            Issue.record("Tracked \(tracked.keys.sorted { $0.raw < $1.raw }) differs from known \(world.windows.keys.sorted { $0.raw < $1.raw }) in \(note)")
            return false
        }
        for (windowID, key) in tracked
        where world.windowDisplay[windowID] != key.displayID || world.windowSpace[windowID] != key.spaceID {
            Issue.record("\(windowID) is tracked in \(key) but recorded on \(String(describing: world.windowDisplay[windowID])) in \(note)")
            return false
        }

        for key in activeWorkspaceKeys(in: world) {
            guard let display = world.displays[key.displayID],
                  let state = world.spaces[key.spaceID]?.displays[key.displayID]
            else { continue }
            guard case .success(let layout) = workspaceLayout(for: key, in: world) else {
                Issue.record("Unsatisfiable layout for \(key) in \(note)")
                return false
            }
            guard Set(layout.tiled.keys) == Set(occupiedWindows(in: state.tree)) else {
                Issue.record("Tiles \(layout.tiled.keys) differ from the tree in \(key) in \(note)")
                return false
            }
            let bounds = display.visibleFrame.insetBy(dx: -0.5, dy: -0.5)
            let frames = layout.tiled.sorted { $0.key.raw < $1.key.raw }
            for (index, (windowID, frame)) in frames.enumerated() {
                guard bounds.contains(frame) else {
                    Issue.record("\(windowID) at \(frame) leaves \(display.visibleFrame) in \(note)")
                    return false
                }
                if let (otherID, _) = frames.dropFirst(index + 1)
                    .first(where: { frame.intersection($0.value).narwhalArea > 0.5 }) {
                    Issue.record("\(windowID) and \(otherID) overlap in \(note)")
                    return false
                }
            }
        }
        return true
    }

    // MARK: - Fixtures

    private func solvedFrames(in world: World) -> [WindowID: CGRect] {
        activeWorkspaceKeys(in: world).reduce(into: [:]) { frames, key in
            if case .success(let layout) = workspaceLayout(for: key, in: world) {
                frames.merge(layout.tiled) { _, solved in solved }
            }
        }
    }

    private func emptyWorld() -> World {
        World(
            displays: displays,
            activeSpace: space,
            spaces: [:],
            windows: [:],
            windowDisplay: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private func environmentChanged(windows: [WindowMetadata], in world: World) throws -> World {
        try apply(.environmentChanged(snapshot(windows: windows)), to: world).get()
    }

    private func snapshot(windows: [WindowMetadata]) -> EnvironmentSnapshot {
        EnvironmentSnapshot(
            activeSpace: space,
            displays: displays,
            axSnapshot: AXWindowSnapshot(
                windows: windows.sorted { $0.id.raw < $1.id.raw },
                quality: .complete
            )
        )
    }

    private func window(_ id: WindowID, onDisplayAt x: CGFloat) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example.sequence"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: CGRect(x: x + 100, y: 100, width: 360, height: 240),
            isResizable: true,
            isMinimized: false
        )
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
