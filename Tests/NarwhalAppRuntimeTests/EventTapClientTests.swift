import CoreGraphics
import Foundation
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("Event tap client")
struct EventTapClientTests {
    @Test("Every pointer-down button reports a possible target raise")
    func pointerDownButtonsReportPossibleTargetRaise() {
        var raiseCount = 0
        let client = makeClient(targetWindowMayRaise: { raiseCount += 1 })
        let point = CGPoint(x: 40, y: 50)

        client.handle(type: .leftMouseDown, location: point, flagsRaw: 0)
        client.handle(type: .rightMouseDown, location: point, flagsRaw: 0)
        client.handle(type: .otherMouseDown, location: point, flagsRaw: 0)

        #expect(raiseCount == 3)
    }

    @Test("Non-left pointer events preserve an active drag")
    func nonLeftPointerEventsPreserveActiveDrag() {
        var raiseCount = 0
        var previews: [CGPoint] = []
        var endCount = 0
        var drops: [CGPoint] = []
        let client = makeClient(
            targetWindowMayRaise: { raiseCount += 1 },
            dragChanged: { previews.append($0) },
            dragEnded: { endCount += 1 },
            drop: { drops.append($0) }
        )
        let down = CGPoint(x: 10, y: 20)
        let dragged = CGPoint(x: 30, y: 40)
        let up = CGPoint(x: 50, y: 60)
        let shift = CGEventFlags.maskShift.rawValue

        client.handle(type: .leftMouseDown, location: down, flagsRaw: shift)
        client.handle(type: .rightMouseDown, location: down, flagsRaw: 0)
        client.handle(type: .otherMouseDown, location: down, flagsRaw: 0)
        client.handle(type: .leftMouseDragged, location: dragged, flagsRaw: shift)
        client.handle(type: .leftMouseUp, location: up, flagsRaw: shift)

        #expect(raiseCount == 3)
        #expect(previews == [down, dragged])
        #expect(endCount == 1)
        #expect(drops == [up])
    }

    private func makeClient(
        targetWindowMayRaise: @escaping () -> Void,
        dragChanged: @escaping (CGPoint) -> Void = { _ in },
        dragEnded: @escaping () -> Void = {},
        drop: @escaping (CGPoint) -> Void = { _ in }
    ) -> EventTapClient {
        EventTapClient(
            modifier: [.shift],
            reporter: StartupReporter(logPath: "/tmp/narwhal-event-tap-tests.log"),
            targetWindowMayRaise: targetWindowMayRaise,
            dragChanged: dragChanged,
            dragEnded: dragEnded,
            drop: drop
        )
    }
}
