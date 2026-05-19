import CoreGraphics

public func resolveDrop(
    _ event: DragEvent,
    zones: [Zone],
    displays: [DisplayID: DisplayInfo]
) -> Command? {
    guard let display = resolveDropDisplay(event, displays: displays) else { return nil }
    let proportionalLocation = proportionalPoint(event.location, in: display.visibleFrame)
    let matches = zones.filter { zone in
        contains(proportionalLocation, in: zone.bounds)
    }
    guard matches.count == 1, let zone = matches.first else { return nil }
    return .dropAtZone(event.windowID, display.id, zone.id)
}

private func resolveDropDisplay(_ event: DragEvent, displays: [DisplayID: DisplayInfo]) -> DisplayInfo? {
    if let displayID = event.displayID {
        guard let display = displays[displayID],
              contains(event.location, in: display.visibleFrame)
        else {
            return nil
        }
        return display
    }

    return displays.values
        .filter { contains(event.location, in: $0.visibleFrame) }
        .sorted { lhs, rhs in lhs.id.raw < rhs.id.raw }
        .first
}

private func proportionalPoint(_ point: CGPoint, in frame: CGRect) -> CGPoint {
    guard frame.width > 0, frame.height > 0 else {
        return CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    }
    return CGPoint(
        x: (point.x - frame.minX) / frame.width,
        y: (point.y - frame.minY) / frame.height
    )
}

private func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
    point.x >= frame.minX
        && point.x < frame.maxX
        && point.y >= frame.minY
        && point.y < frame.maxY
}

private func contains(_ point: CGPoint, in rect: ProportionalRect) -> Bool {
    point.x >= CGFloat(rect.x)
        && point.x < CGFloat(rect.x + rect.w)
        && point.y >= CGFloat(rect.y)
        && point.y < CGFloat(rect.y + rect.h)
}
