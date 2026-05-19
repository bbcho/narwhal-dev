import AppKit
import CoreGraphics
import Foundation
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
                        fingerprint: displayFingerprint(for: displayID),
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

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func displayFingerprint(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
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
