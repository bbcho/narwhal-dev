import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("External geometry event model")
struct ExternalGeometryEventModelTests {
    @Test("Matching live geometry keeps the original event")
    func matchingLiveGeometryKeepsOriginalEvent() {
        let window = WindowID(raw: 10)
        let frame = CGRect(x: 100, y: 200, width: 500, height: 400)
        let event = AXEvent.windowMoved(window, frame.offsetBy(dx: 2, dy: -2))
        let snapshot = AXWindowSnapshot(
            windows: [metadata(window, frame: frame)],
            quality: .complete
        )

        let selection = externalGeometryEventSelection(
            for: event,
            liveSnapshot: snapshot,
            tolerance: 4
        )

        #expect(selection == ExternalGeometryEventSelection(
            event: event,
            usedLiveFrame: false,
            liveFrame: frame
        ))
    }

    @Test("Incomplete live snapshot keeps the original event")
    func incompleteLiveSnapshotKeepsOriginalEvent() {
        let window = WindowID(raw: 20)
        let event = AXEvent.windowMoved(window, CGRect(x: 100, y: 200, width: 500, height: 400))
        let snapshot = AXWindowSnapshot(
            windows: [metadata(window, frame: CGRect(x: 200, y: 300, width: 500, height: 400))],
            quality: .partial([AXWindowReadError(windowID: nil, pid: nil, message: "busy")])
        )

        let selection = externalGeometryEventSelection(
            for: event,
            liveSnapshot: snapshot,
            tolerance: 4
        )

        #expect(selection == ExternalGeometryEventSelection(event: event, usedLiveFrame: false))
    }

    @Test("Stale move event converges to settled live frame")
    func staleMoveEventConvergesToSettledLiveFrame() {
        let window = WindowID(raw: 30)
        let stale = CGRect(x: 100, y: 200, width: 500, height: 400)
        let live = CGRect(x: 112, y: 213, width: 510, height: 390)
        let snapshot = AXWindowSnapshot(
            windows: [metadata(window, frame: live)],
            quality: .complete
        )

        let selection = externalGeometryEventSelection(
            for: .windowMoved(window, stale),
            liveSnapshot: snapshot,
            tolerance: 4
        )

        #expect(selection == ExternalGeometryEventSelection(
            event: .windowMoved(window, live),
            usedLiveFrame: true,
            liveFrame: live
        ))
    }

    @Test("Stale resize event converges to full settled live frame")
    func staleResizeEventConvergesToFullSettledLiveFrame() {
        let window = WindowID(raw: 40)
        let live = CGRect(x: 95, y: 200, width: 510, height: 390)
        let snapshot = AXWindowSnapshot(
            windows: [metadata(window, frame: live)],
            quality: .complete
        )

        let selection = externalGeometryEventSelection(
            for: .windowResized(window, CGSize(width: 500, height: 400)),
            liveSnapshot: snapshot,
            tolerance: 4
        )

        #expect(selection == ExternalGeometryEventSelection(
            event: .windowMoved(window, live),
            usedLiveFrame: true,
            liveFrame: live
        ))
    }

    @Test("Selected stale event records settled frame in world state")
    func selectedStaleEventRecordsSettledFrameInWorldState() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let window = WindowID(raw: 50)
        let oldFrame = CGRect(x: 80, y: 120, width: 480, height: 360)
        let staleFrame = CGRect(x: 100, y: 140, width: 500, height: 380)
        let liveFrame = CGRect(x: 112, y: 151, width: 510, height: 390)
        let world = World(
            displays: [
                display: DisplayInfo(
                    id: display,
                    slot: 0,
                    fingerprint: "main",
                    frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 860)
                )
            ],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        display: DisplaySpaceState(
                            displayID: display,
                            tree: .void,
                            floating: [window]
                        )
                    ],
                    focused: window
                )
            ],
            windows: [window: metadata(window, frame: oldFrame)],
            windowDisplay: [window: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let selection = externalGeometryEventSelection(
            for: .windowMoved(window, staleFrame),
            liveSnapshot: AXWindowSnapshot(
                windows: [metadata(window, frame: liveFrame)],
                quality: .complete
            ),
            tolerance: 4
        )

        let next = try apply(selection.event.toCommand(), to: world).get()

        #expect(next.windows[window]?.frame == liveFrame)
    }

    @Test("Manual geometry preserves the settled live source frame")
    func manualGeometryPreservesSettledLiveSourceFrame() {
        let window = WindowID(raw: 55)
        let liveFrame = CGRect(x: 112, y: 151, width: 510, height: 390)
        let selection = ExternalGeometryEventSelection(
            event: .windowResized(window, liveFrame.size),
            usedLiveFrame: false,
            liveFrame: liveFrame
        )
        let plan = CommandPlanResult(
            focusedWindowID: nil,
            desiredLayout: DesiredLayout(
                generation: LayoutGeneration(raw: 1),
                layout: Layout(tiled: [window: liveFrame], floatingZOrder: [], hidden: []),
                delta: LayoutDelta(moves: [window: liveFrame], raises: [], hides: [], shows: [])
            ),
            windows: [window: metadata(window, frame: liveFrame)],
            sourceWorld: .empty,
            plannedWorld: .empty,
            undoWorld: nil
        )

        #expect(preservedExternalGeometryFrames(selection: selection, plan: plan) == [window: liveFrame])
    }

    @Test("Pending geometry queue drains one latest event per window")
    func pendingGeometryQueueDrainsOneLatestEventPerWindow() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 60)
        let second = WindowID(raw: 61)
        let firstOldFrame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let secondOldFrame = CGRect(x: 500, y: 0, width: 500, height: 400)
        let firstNewFrame = CGRect(x: 10, y: 20, width: 510, height: 390)
        let secondStaleFrame = CGRect(x: 520, y: 10, width: 480, height: 390)
        let secondNewFrame = CGRect(x: 530, y: 20, width: 470, height: 380)
        var queue = ExternalGeometryEventQueue<AXEvent>()
        queue.enqueue(.windowMoved(second, secondStaleFrame), for: second)
        queue.enqueue(.windowMoved(first, firstNewFrame), for: first)
        queue.enqueue(.windowMoved(second, secondNewFrame), for: second)

        #expect(queue.count == 2)

        let world = twoWindowWorld(
            display: display,
            space: space,
            first: metadata(first, frame: firstOldFrame),
            second: metadata(second, frame: secondOldFrame)
        )
        var next = world
        var drained: [AXEvent] = []
        while let event = queue.dequeue() {
            drained.append(event)
            next = try apply(event.toCommand(), to: next).get()
        }

        #expect(drained == [
            .windowMoved(second, secondNewFrame),
            .windowMoved(first, firstNewFrame)
        ])
        #expect(next.windows[first]?.frame == firstNewFrame)
        #expect(next.windows[second]?.frame == secondNewFrame)
        #expect(queue.isEmpty)
        #expect(queue.count == 0)
    }

    private func twoWindowWorld(
        display: DisplayID,
        space: SpaceID,
        first: WindowMetadata,
        second: WindowMetadata
    ) -> World {
        World(
            displays: [
                display: DisplayInfo(
                    id: display,
                    slot: 0,
                    fingerprint: "main",
                    frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 860)
                )
            ],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [
                        display: DisplaySpaceState(
                            displayID: display,
                            tree: .void,
                            floating: [first.id, second.id]
                        )
                    ],
                    focused: first.id
                )
            ],
            windows: [first.id: first, second.id: second],
            windowDisplay: [first.id: display, second.id: display],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
    }

    private func metadata(_ id: WindowID, frame: CGRect) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example.app"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(id.raw),
            frame: frame,
            isResizable: true,
            isMinimized: false
        )
    }
}
