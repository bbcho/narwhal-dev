import CoreGraphics
import NarwhalCore

public struct ExternalGeometryEventSelection: Equatable, Sendable {
    public let event: AXEvent
    public let usedLiveFrame: Bool
    public let liveFrame: CGRect?

    public init(event: AXEvent, usedLiveFrame: Bool, liveFrame: CGRect? = nil) {
        self.event = event
        self.usedLiveFrame = usedLiveFrame
        self.liveFrame = liveFrame
    }
}

public struct ExternalGeometryEventQueue<Event: Sendable>: Sendable {
    private var windowOrder: [WindowID]
    private var eventsByWindow: [WindowID: Event]

    public init() {
        self.windowOrder = []
        self.eventsByWindow = [:]
    }

    public var isEmpty: Bool {
        eventsByWindow.isEmpty
    }

    public var count: Int {
        eventsByWindow.count
    }

    public mutating func enqueue(_ event: Event, for windowID: WindowID) {
        if eventsByWindow[windowID] == nil {
            windowOrder.append(windowID)
        }
        eventsByWindow[windowID] = event
    }

    public mutating func dequeue() -> Event? {
        while !windowOrder.isEmpty {
            let windowID = windowOrder.removeFirst()
            if let event = eventsByWindow.removeValue(forKey: windowID) {
                return event
            }
        }
        return nil
    }
}

extension ExternalGeometryEventQueue: Equatable where Event: Equatable {}

public func externalGeometryWindowID(for event: AXEvent) -> WindowID? {
    switch event {
    case .windowMoved(let id, _), .windowResized(let id, _):
        return id
    case .windowOpened, .windowClosed, .windowFocused:
        return nil
    }
}

public func externalGeometryEventSelection(
    for event: AXEvent,
    liveSnapshot: AXWindowSnapshot,
    tolerance: CGFloat
) -> ExternalGeometryEventSelection {
    guard let windowID = externalGeometryWindowID(for: event) else {
        return ExternalGeometryEventSelection(event: event, usedLiveFrame: false)
    }

    guard case .complete = liveSnapshot.quality,
          let live = liveSnapshot.windows.first(where: { $0.id == windowID })
    else {
        return ExternalGeometryEventSelection(event: event, usedLiveFrame: false)
    }

    let matchesLiveFrame: Bool
    switch event {
    case .windowMoved(_, let frame):
        matchesLiveFrame = live.frame.narwhalApproximatelyEquals(frame, tolerance: tolerance)
    case .windowResized(_, let size):
        matchesLiveFrame = live.frame.size.narwhalApproximatelyEquals(size, tolerance: tolerance)
    case .windowOpened, .windowClosed, .windowFocused:
        matchesLiveFrame = true
    }

    guard !matchesLiveFrame else {
        return ExternalGeometryEventSelection(event: event, usedLiveFrame: false, liveFrame: live.frame)
    }
    return ExternalGeometryEventSelection(
        event: .windowMoved(windowID, live.frame),
        usedLiveFrame: true,
        liveFrame: live.frame
    )
}

public func preservedExternalGeometryFrames(
    selection: ExternalGeometryEventSelection,
    plan: CommandPlanResult
) -> [WindowID: CGRect] {
    guard let windowID = externalGeometryWindowID(for: selection.event),
          let frame = selection.liveFrame ?? plan.plannedWorld.windows[windowID]?.frame
    else { return [:] }
    return [windowID: frame]
}
