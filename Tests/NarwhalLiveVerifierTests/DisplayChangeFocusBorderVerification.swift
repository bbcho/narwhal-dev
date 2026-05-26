#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

@MainActor
enum DisplayChangeFocusBorderVerification {
    static func verifyDisplayChangePreservesVisibleFocusBorder() -> (passed: Bool, message: String) {
        let focusFrame = CGRect(x: 120, y: 120, width: 420, height: 280)
        let tiledFrame = CGRect(x: 620, y: 120, width: 360, height: 240)
        let focusWindow = makeWindow(frame: focusFrame, color: .systemBlue)
        let tiledWindow = makeWindow(frame: tiledFrame, color: .systemGreen)
        let overlay = Overlay(border: Config.default.border, hud: Config.default.hud)
        defer {
            overlay.stop()
            focusWindow.orderOut(nil)
            tiledWindow.orderOut(nil)
        }

        focusWindow.orderFrontRegardless()
        tiledWindow.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let focusID = WindowID(raw: CGWindowID(focusWindow.windowNumber))
        let tiledID = WindowID(raw: CGWindowID(tiledWindow.windowNumber))
        guard let liveFocusFrame = windowServerFrame(for: focusWindow.windowNumber),
              let liveTiledFrame = windowServerFrame(for: tiledWindow.windowNumber)
        else {
            return (false, "display-change focus verifier could not read initial live window frames")
        }
        var model = OverlayModel.empty
            .showingFocusBorder(FocusBorderTarget(windowID: focusID, frame: liveFocusFrame, cornerRadius: 15))
            .settingTiledBorders([
                FocusBorderTarget(windowID: tiledID, frame: liveTiledFrame, cornerRadius: 15)
            ])
        overlay.render(model)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        guard overlay.debugFocusBorderWindowID() == focusID,
              overlay.debugFocusBorderIsVisible(),
              overlay.debugVisibleTiledBorderCount() == 1
        else {
            return (false, "display-change focus verifier did not establish initial focus and tiled borders")
        }
        guard let initialFocusNumber = overlay.debugFocusBorderWindowNumber(),
              focusBorderIsVisible(overlay: overlay, focusID: focusID, focusWindow: focusWindow)
        else {
            return (false, "display-change focus verifier initial focus border was not visibly above target")
        }

        model = model.settingTiledBorders([])
        overlay.render(model)

        let unavailable = reduceFocusedWindowObservation(
            state: FocusedWindowObservationState(
                geometry: FocusedWindowGeometryState(windowID: focusID, frame: liveFocusFrame)
            ),
            input: .unavailable,
            tolerance: 1
        )
        guard unavailable.effects.isEmpty else {
            return (false, "focused-window unavailable produced a hide effect during display-change preservation")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        guard overlay.debugTiledBorderWindowIDs().isEmpty,
              overlay.debugVisibleTiledBorderCount() == 0
        else {
            return (false, "display-change cleanup did not clear tiled borders")
        }
        guard overlay.debugFocusBorderWindowNumber() == initialFocusNumber,
              focusBorderIsVisible(overlay: overlay, focusID: focusID, focusWindow: focusWindow)
        else {
            return (false, "display-change cleanup hid or buried the focus border")
        }

        return (
            true,
            "display-change focus border verified: focus=\(focusID.description) border=\(initialFocusNumber) tiledCleared=\(tiledID.description)"
        )
    }

    private static func focusBorderIsVisible(
        overlay: Overlay,
        focusID: WindowID,
        focusWindow: NSWindow
    ) -> Bool {
        guard overlay.debugFocusBorderWindowID() == focusID,
              overlay.debugFocusBorderIsVisible(),
              let borderNumber = overlay.debugFocusBorderWindowNumber(),
              let orderedWindowNumbers = waitForFrontToBackWindowNumbers(containing: [
                  borderNumber,
                  focusWindow.windowNumber
              ]),
              let borderIndex = orderedWindowNumbers.firstIndex(of: borderNumber),
              let targetIndex = orderedWindowNumbers.firstIndex(of: focusWindow.windowNumber)
        else {
            return false
        }
        return borderIndex < targetIndex
    }

    private static func waitForFrontToBackWindowNumbers(containing required: [Int]) -> [Int]? {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let ordered = frontToBackWindowNumbers()
            if required.allSatisfy({ ordered.contains($0) }) {
                return ordered
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return nil
    }

    private static func frontToBackWindowNumbers() -> [Int] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else { return [] }

        return windows.compactMap { window in
            if let number = window[kCGWindowNumber as String] as? CGWindowID {
                return Int(number)
            }
            if let number = window[kCGWindowNumber as String] as? Int {
                return number
            }
            return nil
        }
    }

    private static func windowServerFrame(for windowNumber: Int) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowNumber)
        ) as? [[String: Any]]
        else { return nil }

        for window in windows {
            let rawNumber = window[kCGWindowNumber as String]
            let number = (rawNumber as? CGWindowID).map(Int.init) ?? rawNumber as? Int
            guard number == windowNumber,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            return frame
        }
        return nil
    }

    private static func makeWindow(frame: CGRect, color: NSColor) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = color
        window.isOpaque = true
        window.hasShadow = false
        window.level = .normal
        window.collectionBehavior = [.ignoresCycle]
        window.orderFrontRegardless()
        return window
    }
}
#endif
