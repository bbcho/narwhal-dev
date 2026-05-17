import AppKit
import CoreGraphics
import WinMgrCore

struct DisplayClient {
    func currentDisplays() -> [DisplayID: DisplayInfo] {
        let screens = NSScreen.screens.sorted { lhs, rhs in
            if lhs.frame.minX == rhs.frame.minX {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }

        return Dictionary(uniqueKeysWithValues: screens.enumerated().compactMap { slot, screen in
            guard let displayID = displayID(for: screen) else { return nil }
            let id = DisplayID(raw: displayID)
            let frame = CGDisplayBounds(displayID)
            let visibleFrame = axVisibleFrame(for: screen, displayFrame: frame)
            return (
                id,
                DisplayInfo(
                    id: id,
                    slot: slot,
                    fingerprint: nil,
                    frame: frame,
                    visibleFrame: visibleFrame
                )
            )
        })
    }

    func displayContaining(frame: CGRect, displays: [DisplayID: DisplayInfo]) -> DisplayID? {
        if let byIntersection = displays.max(by: { lhs, rhs in
            lhs.value.visibleFrame.intersection(frame).area < rhs.value.visibleFrame.intersection(frame).area
        }), byIntersection.value.visibleFrame.intersection(frame).area > 0 {
            return byIntersection.key
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min(by: { lhs, rhs in
            lhs.value.visibleFrame.center.distanceSquared(to: center) < rhs.value.visibleFrame.center.distanceSquared(to: center)
        })?.key
    }

    func leftHalf(of display: DisplayInfo, gaps: Gaps = .init(inner: 0, outer: .init(top: 0, left: 0, bottom: 0, right: 0))) -> CGRect {
        let frame = display.visibleFrame
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func axVisibleFrame(for screen: NSScreen, displayFrame: CGRect) -> CGRect {
        let appFrame = screen.frame
        let appVisible = screen.visibleFrame
        return CGRect(
            x: displayFrame.minX + (appVisible.minX - appFrame.minX),
            y: displayFrame.minY + (appFrame.maxY - appVisible.maxY),
            width: appVisible.width,
            height: appVisible.height
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
