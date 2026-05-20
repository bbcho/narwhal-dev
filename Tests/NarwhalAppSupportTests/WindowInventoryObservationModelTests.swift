import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Window inventory observation model")
struct WindowInventoryObservationModelTests {
    @Test("Baseline records visible windows, frames, and Space")
    func baselineRecordsInventoryFramesAndSpace() {
        let space = SpaceID(raw: 3)
        let first = metadata(WindowID(raw: 10))
        let second = metadata(WindowID(raw: 20), frame: CGRect(x: 40, y: 50, width: 600, height: 500))

        let state = windowInventoryObservationBaseline(windows: [second, first], spaceID: space)

        #expect(state.inventory == WindowInventoryState(visibleWindowIDs: [first.id, second.id]))
        #expect(state.frameInventory == WindowFrameInventoryState(framesByWindowID: [
            first.id: first.frame,
            second.id: second.frame
        ]))
        #expect(state.spaceID == space)
    }

    @Test("First observation initializes baseline without emitting events")
    func firstObservationInitializesBaselineWithoutEvents() {
        let window = metadata(WindowID(raw: 30))

        let transition = observeWindowInventory(
            windows: [window],
            spaceID: SpaceID(raw: 4),
            tolerance: 1,
            in: .empty
        )

        #expect(transition.state == windowInventoryObservationBaseline(windows: [window], spaceID: SpaceID(raw: 4)))
        #expect(transition.events == [])
        #expect(transition.frameEvents == [])
        #expect(transition.effect == nil)
    }

    @Test("Space change requests boundary reset instead of diffing unrelated windows")
    func spaceChangeRequestsBoundaryReset() {
        let original = metadata(WindowID(raw: 40))
        let state = windowInventoryObservationBaseline(windows: [original], spaceID: SpaceID(raw: 1))

        let transition = observeWindowInventory(
            windows: [metadata(WindowID(raw: 41))],
            spaceID: SpaceID(raw: 2),
            tolerance: 1,
            in: state
        )

        #expect(transition.state == .empty)
        #expect(transition.events == [])
        #expect(transition.frameEvents == [])
        #expect(transition.effect == .activeSpaceChanged)
    }

    @Test("Likely Space replacement suppresses bulk window churn and resets boundary")
    func likelySpaceReplacementSuppressesBulkWindowChurn() {
        let state = windowInventoryObservationBaseline(
            windows: [
                metadata(WindowID(raw: 50)),
                metadata(WindowID(raw: 51)),
                metadata(WindowID(raw: 52))
            ],
            spaceID: SpaceID(raw: 5)
        )
        let replacement = [
            metadata(WindowID(raw: 60)),
            metadata(WindowID(raw: 61)),
            metadata(WindowID(raw: 62))
        ]

        let transition = observeWindowInventory(
            windows: replacement,
            spaceID: SpaceID(raw: 5),
            tolerance: 1,
            in: state
        )

        #expect(transition.state == .empty)
        #expect(transition.events == [])
        #expect(transition.frameEvents == [])
        #expect(transition.effect == .likelySpaceReplacement)
    }

    @Test("Normal observation emits inventory events and updates baseline")
    func normalObservationEmitsInventoryEvents() {
        let staying = metadata(WindowID(raw: 70))
        let opened = metadata(WindowID(raw: 71))
        let state = windowInventoryObservationBaseline(
            windows: [staying],
            spaceID: SpaceID(raw: 7)
        )

        let transition = observeWindowInventory(
            windows: [opened, staying],
            spaceID: SpaceID(raw: 7),
            tolerance: 1,
            in: state
        )

        #expect(transition.state.inventory == WindowInventoryState(visibleWindowIDs: [staying.id, opened.id]))
        #expect(transition.events == [
            .windowOpened(opened)
        ])
        #expect(transition.frameEvents == [])
        #expect(transition.effect == nil)
    }

    @Test("Frame changes emit separate geometry events while retaining inventory state")
    func frameChangesEmitGeometryEvents() {
        let first = metadata(WindowID(raw: 80))
        let second = metadata(WindowID(raw: 81))
        let state = windowInventoryObservationBaseline(
            windows: [first, second],
            spaceID: SpaceID(raw: 8)
        )
        let movedFirst = metadata(first.id, frame: first.frame.offsetBy(dx: 20, dy: 0))
        let resizedSecond = metadata(
            second.id,
            frame: CGRect(x: second.frame.minX, y: second.frame.minY, width: 350, height: 250)
        )

        let transition = observeWindowInventory(
            windows: [resizedSecond, movedFirst],
            spaceID: SpaceID(raw: 8),
            tolerance: 1,
            in: state
        )

        #expect(transition.state.inventory == WindowInventoryState(visibleWindowIDs: [first.id, second.id]))
        #expect(transition.state.frameInventory == WindowFrameInventoryState(framesByWindowID: [
            first.id: movedFirst.frame,
            second.id: resizedSecond.frame
        ]))
        #expect(transition.events == [])
        #expect(transition.frameEvents == [
            .windowMoved(first.id, movedFirst.frame),
            .windowResized(second.id, resizedSecond.frame.size)
        ])
        #expect(transition.effect == nil)
    }

    private func metadata(
        _ id: WindowID,
        frame: CGRect? = nil
    ) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example.\(id.raw)"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: frame ?? CGRect(x: Double(id.raw) * 10, y: 20, width: 200, height: 150),
            isResizable: true,
            isMinimized: false
        )
    }
}
