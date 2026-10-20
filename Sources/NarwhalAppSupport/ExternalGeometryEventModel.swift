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

    guard snapshotIsTrustworthy(liveSnapshot.quality, for: windowID),
          let live = liveSnapshot.windows.first(where: { $0.id == windowID })
    else {
        return ExternalGeometryEventSelection(event: event, usedLiveFrame: false)
    }

    let matchesLiveFrame: Bool
    switch event {
    case .windowMoved(_, let frame):
        matchesLiveFrame = live.frame.narwhalApproximatelyEquals(frame, tolerance: tolerance)
    case .windowResized:
        // Size alone cannot identify a left/top-edge drag: its origin moves too.
        matchesLiveFrame = false
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

/// A partial snapshot still describes this window reliably when every read
/// error names some other window; an unattributed error could be this one.
private func snapshotIsTrustworthy(_ quality: AXSnapshotQuality, for windowID: WindowID) -> Bool {
    switch quality {
    case .complete:
        return true
    case .partial(let errors):
        return errors.allSatisfy { error in
            error.windowID.map { $0 != windowID } ?? false
        }
    case .permissionDenied, .unavailable:
        return false
    }
}

public func preservedExternalGeometryFrames(
    selection: ExternalGeometryEventSelection,
    plan: CommandPlanResult
) -> [WindowID: CGRect] {
    guard let windowID = externalGeometryWindowID(for: selection.event),
          let frame = selection.liveFrame ?? plan.plannedWorld.windows[windowID]?.frame
    else { return [:] }
    // Only leave the dragged window alone when the plan already agrees with where
    // the user put it; a snap-back plan must write it.
    if let planned = plan.desiredLayout.layout.tiled[windowID],
       !planned.narwhalApproximatelyEquals(frame, tolerance: frameWriteSettleTolerance) {
        return [:]
    }
    return [windowID: frame]
}
