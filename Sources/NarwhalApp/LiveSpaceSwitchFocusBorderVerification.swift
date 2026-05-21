import AppKit
import CoreGraphics
import Foundation
import NarwhalAppSupport
import NarwhalCore

@MainActor
enum LiveSpaceSwitchFocusBorderVerification {
    static func verifyFocusBorderMovesAcrossRealSpaceSwitch() -> (passed: Bool, message: String) {
        let spaceClient = SpaceClient()
        do {
            let displays = DisplayClient().currentDisplays()
            guard let display = displays.values.sorted(by: { $0.slot < $1.slot }).first else {
                return (false, "live Space-switch focus border verification requires at least one display")
            }
            guard display.visibleFrame.width >= 480,
                  display.visibleFrame.height >= 320
            else {
                return (
                    false,
                    "live Space-switch focus border verification requires a usable display; visible=\(display.visibleFrame.debugDescription)"
                )
            }

            let originalSpace = try activeSpaceID(for: display, using: spaceClient, displays: displays)
            let overlay = Overlay(border: Config.default.border, hud: Config.default.hud)
            let firstTarget = makeWindow(
                title: "Narwhal live Space switch focus A",
                axFrame: sampleFrame(in: display.visibleFrame, offset: .zero),
                display: display,
                color: .systemBlue
            )
            var secondTarget: NSWindow?
            var switched: SpaceSwitch?

            defer {
                overlay.stop()
                firstTarget.orderOut(nil)
                secondTarget?.orderOut(nil)
                if let switched {
                    _ = restoreOriginalSpace(switched, using: spaceClient)
                }
            }

            firstTarget.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            let firstID = WindowID(raw: CGWindowID(firstTarget.windowNumber))
            overlay.render(OverlayModel.empty.showingFocusBorder(
                FocusBorderTarget(windowID: firstID, frame: sampleFrame(in: display.visibleFrame, offset: .zero), cornerRadius: 15)
            ))
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            try requireFocusBorderVisibleAbove(
                overlay: overlay,
                targetID: firstID,
                targetWindow: firstTarget,
                context: "before Space switch"
            )

            switched = try switchToAdjacentSpace(
                from: originalSpace,
                on: display,
                using: spaceClient,
                displays: displays
            )
            let secondFrame = sampleFrame(in: display.visibleFrame, offset: CGPoint(x: 36, y: 36))
            let nextTarget = makeWindow(
                title: "Narwhal live Space switch focus B",
                axFrame: secondFrame,
                display: display,
                color: .systemGreen
            )
            secondTarget = nextTarget
            nextTarget.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.18))

            let secondID = WindowID(raw: CGWindowID(nextTarget.windowNumber))
            overlay.render(OverlayModel.empty.showingFocusBorder(
                FocusBorderTarget(windowID: secondID, frame: secondFrame, cornerRadius: 15)
            ))
            RunLoop.current.run(until: Date().addingTimeInterval(0.18))
            try requireFocusBorderVisibleAbove(
                overlay: overlay,
                targetID: secondID,
                targetWindow: nextTarget,
                context: "after Space switch"
            )

            let destinationSpace = switched!.destination
            let restored = restoreOriginalSpace(switched!, using: spaceClient)
            switched = nil
            guard restored else {
                return (
                    false,
                    "live Space-switch focus border verification passed on destination Space but could not restore original Space \(originalSpace.raw)"
                )
            }

            return (
                true,
                [
                    "live Space-switch focus border verified:",
                    "spaces=\(originalSpace.raw),\(destinationSpace.raw)",
                    "targetA=w\(firstID.raw)",
                    "targetB=w\(secondID.raw)"
                ].joined(separator: " ")
            )
        } catch let error as SpaceSwitchFocusBorderFailure {
            return (false, error.message)
        } catch {
            return (false, "live Space-switch focus border verification failed: \(String(describing: error))")
        }
    }

    private static func switchToAdjacentSpace(
        from original: SpaceID,
        on display: DisplayInfo,
        using spaceClient: SpaceClient,
        displays: [DisplayID: DisplayInfo]
    ) throws -> SpaceSwitch {
        let rows = spaceClient.managedDisplaySpaceRows(displays: displays)
        guard let row = rows[display.id],
              let activeIndex = row.spaces.firstIndex(where: { $0.id == original })
        else {
            throw SpaceSwitchFocusBorderFailure(
                "live Space-switch focus border verification could not find active Space \(original.raw) in managed Spaces for display \(display.id.raw)"
            )
        }
        guard row.spaces.count >= 2 else {
            throw SpaceSwitchFocusBorderFailure(
                "live Space-switch focus border verification requires at least two Spaces on display \(display.id.raw); found \(row.spaces.count)"
            )
        }

        let nextIndex = activeIndex + 1
        let previousIndex = activeIndex - 1
        let destination = (row.spaces.indices.contains(nextIndex) ? row.spaces[nextIndex].id : nil)
            ?? (row.spaces.indices.contains(previousIndex) ? row.spaces[previousIndex].id : nil)
        guard let destination else {
            throw SpaceSwitchFocusBorderFailure(
                "live Space-switch focus border verification could not choose an adjacent Space from \(row.spaces.map(\.id.raw))"
            )
        }

        switch spaceClient.switchActiveSpace(display: display, to: destination) {
        case .success:
            break
        case .failure(let error):
            throw SpaceSwitchFocusBorderFailure(
                "live Space-switch focus border verification could not switch to Space \(destination.raw): \(error.description)"
            )
        }

        guard waitForDisplaySpace(destination, display: display, using: spaceClient, displays: displays, timeout: 3.0) != nil else {
            throw SpaceSwitchFocusBorderFailure(
                "live Space-switch focus border verification requested Space \(destination.raw), but display \(display.id.raw) stayed on \(activeSpaceDescription(for: display, using: spaceClient, displays: displays))"
            )
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        return SpaceSwitch(original: original, destination: destination, display: display)
    }

    private static func restoreOriginalSpace(_ switched: SpaceSwitch, using spaceClient: SpaceClient) -> Bool {
        let displays = DisplayClient().currentDisplays()
        if activeSpaceIDOrNil(for: switched.display, using: spaceClient, displays: displays) == switched.original {
            return true
        }
        guard case .success = spaceClient.switchActiveSpace(display: switched.display, to: switched.original) else {
            return false
        }
        let restored = waitForDisplaySpace(
            switched.original,
            display: switched.display,
            using: spaceClient,
            displays: displays,
            timeout: 3.0
        ) != nil
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        return restored
    }

    private static func activeSpaceID(
        for display: DisplayInfo,
        using spaceClient: SpaceClient,
        displays: [DisplayID: DisplayInfo]
    ) throws -> SpaceID {
        if let active = activeSpaceIDOrNil(for: display, using: spaceClient, displays: displays) {
            return active
        }
        throw SpaceSwitchFocusBorderFailure(
            "live Space-switch focus border verification could not read managed active Space for display \(display.id.raw)"
        )
    }

    private static func activeSpaceIDOrNil(
        for display: DisplayInfo,
        using spaceClient: SpaceClient,
        displays: [DisplayID: DisplayInfo]
    ) -> SpaceID? {
        spaceClient.managedDisplaySpaceRows(displays: displays)[display.id]?.activeSpace
    }

    private static func waitForDisplaySpace(
        _ expected: SpaceID,
        display: DisplayInfo,
        using spaceClient: SpaceClient,
        displays: [DisplayID: DisplayInfo],
        timeout: TimeInterval
    ) -> SpaceID? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let spaceID = activeSpaceIDOrNil(for: display, using: spaceClient, displays: displays),
               spaceID == expected {
                return spaceID
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private static func requireFocusBorderVisibleAbove(
        overlay: Overlay,
        targetID: WindowID,
        targetWindow: NSWindow,
        context: String
    ) throws {
        guard overlay.debugFocusBorderWindowID() == targetID,
              overlay.debugFocusBorderIsVisible(),
              let borderNumber = overlay.debugFocusBorderWindowNumber(),
              let orderedWindowNumbers = waitForFrontToBackWindowNumbers(containing: [
                  borderNumber,
                  targetWindow.windowNumber
              ]),
              let borderIndex = orderedWindowNumbers.firstIndex(of: borderNumber),
              let targetIndex = orderedWindowNumbers.firstIndex(of: targetWindow.windowNumber),
              borderIndex < targetIndex
        else {
            throw SpaceSwitchFocusBorderFailure(
                "live Space-switch focus border was not visibly above target \(context): target=\(targetWindow.windowNumber) border=\(String(describing: overlay.debugFocusBorderWindowNumber())) visible=\(overlay.debugFocusBorderIsVisible())"
            )
        }
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

    private static func makeWindow(
        title: String,
        axFrame: CGRect,
        display: DisplayInfo,
        color: NSColor
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: appKitFrame(forAXFrame: axFrame, display: display),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.backgroundColor = color
        window.isOpaque = true
        window.hasShadow = false
        window.level = .normal
        window.collectionBehavior = [.ignoresCycle]
        return window
    }

    private static func sampleFrame(in visibleFrame: CGRect, offset: CGPoint) -> CGRect {
        let width = min(max(visibleFrame.width * 0.38, 360), visibleFrame.width - 96)
        let height = min(max(visibleFrame.height * 0.34, 260), visibleFrame.height - 96)
        return CGRect(
            x: visibleFrame.midX - width / 2 + offset.x,
            y: visibleFrame.midY - height / 2 + offset.y,
            width: width,
            height: height
        )
    }

    private static func appKitFrame(forAXFrame frame: CGRect, display: DisplayInfo) -> CGRect {
        let screenFrame = screenFrame(for: display.id) ?? display.frame
        return CGRect(
            x: screenFrame.minX + (frame.minX - display.frame.minX),
            y: screenFrame.minY + (display.frame.maxY - frame.maxY),
            width: frame.width,
            height: frame.height
        )
    }

    private static func screenFrame(for displayID: DisplayID) -> CGRect? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID.raw
        }?.frame
    }

    private static func activeSpaceDescription(
        for display: DisplayInfo,
        using spaceClient: SpaceClient,
        displays: [DisplayID: DisplayInfo]
    ) -> String {
        activeSpaceIDOrNil(for: display, using: spaceClient, displays: displays)
            .map { String($0.raw) }
            ?? "unknown"
    }
}

private struct SpaceSwitch: Sendable {
    let original: SpaceID
    let destination: SpaceID
    let display: DisplayInfo
}

private struct SpaceSwitchFocusBorderFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
