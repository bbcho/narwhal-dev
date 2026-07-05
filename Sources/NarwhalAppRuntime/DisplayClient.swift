import AppKit
import CoreGraphics
import Foundation
import NarwhalCore

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
        displayContainingFrame(frame, displays: displays)
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
