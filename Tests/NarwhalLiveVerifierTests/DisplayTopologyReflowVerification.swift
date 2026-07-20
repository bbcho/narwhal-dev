#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import CoreGraphics
import Darwin
import NarwhalAppSupport
import NarwhalCore

@MainActor
enum DisplayTopologyReflowVerification {
    static func verifyCurrentDisplayReflow() -> (passed: Bool, message: String) {
        guard !isSystemLocked() else {
            return (false, "display topology reflow verification requires an unlocked user session")
        }
        guard let display = DisplayClient().currentDisplays().values.max(by: {
            $0.visibleFrame.narwhalArea < $1.visibleFrame.narwhalArea
        }), display.visibleFrame.width >= 800, display.visibleFrame.height >= 600 else {
            return (false, "display topology reflow verification requires an 800x600 visible display")
        }

        let firstStart = stagedFrame(in: display.visibleFrame, leading: true)
        let secondStart = stagedFrame(in: display.visibleFrame, leading: false)
        let first = makeWindow(title: "Narwhal topology first", frame: firstStart, display: display, color: .systemBlue)
        let second = makeWindow(title: "Narwhal topology second", frame: secondStart, display: display, color: .systemOrange)
        let windows = [first, second]
        let overlay = Overlay(border: Config.default.border, hud: Config.default.hud)
        defer {
            overlay.stop()
            windows.forEach { $0.window.orderOut(nil) }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        let removedID = DisplayID(raw: display.id.raw == 4_000_000_001 ? 4_000_000_002 : 4_000_000_001)
        let removedDisplay = DisplayInfo(
            id: removedID,
            slot: display.slot + 1,
            fingerprint: "removed-live-verifier",
            frame: display.frame.offsetBy(dx: display.frame.width, dy: 0),
            visibleFrame: display.visibleFrame.offsetBy(dx: display.frame.width, dy: 0)
        )
        let spaceID = SpaceID(raw: 980_001)
        let original = World(
            displays: [display.id: display, removedID: removedDisplay],
            activeSpace: spaceID,
            activeSpaceByDisplay: [display.id: spaceID, removedID: spaceID],
            spaces: [
                spaceID: SpaceState(
                    id: spaceID,
                    displays: [
                        display.id: DisplaySpaceState(displayID: display.id, tree: .leaf(first.id), floating: []),
                        removedID: DisplaySpaceState(displayID: removedID, tree: .leaf(second.id), floating: [])
                    ],
                    focused: first.id
                )
            ],
            windows: [first.id: first.metadata, second.id: second.metadata],
            windowDisplay: [first.id: display.id, second.id: removedID],
            windowSpace: [first.id: spaceID, second.id: spaceID],
            observedVisibleWindows: [:],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let snapshot = EnvironmentSnapshot(
            activeSpace: spaceID,
            displays: [display.id: display],
            axSnapshot: AXWindowSnapshot(windows: windows.map(\.metadata), quality: .complete),
            spaceTopology: SpaceTopology(
                activeSpaceByDisplay: [display.id: spaceID],
                windowSpace: [first.id: spaceID, second.id: spaceID],
                quality: .managedDisplaySpaces
            ),
            reconciliationMode: .displayTopologySettled
        )
        let reconciled = reconcileEnvironment(snapshot, in: original)
        guard reconciled.spaces[spaceID]?.displays[removedID] == nil,
              case .success(let layout) = flattenedLayout(of: reconciled),
              let firstTarget = layout.tiled[first.id],
              let secondTarget = layout.tiled[second.id],
              firstTarget.intersection(secondTarget).narwhalArea <= 0.25
        else {
            return (false, "display topology reflow did not merge both tiled windows onto the surviving display")
        }

        setAXFrame(first.window, to: firstTarget, display: display)
        setAXFrame(second.window, to: secondTarget, display: display)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        for (live, target) in [(first, firstTarget), (second, secondTarget)] {
            guard live.window.frame.matches(appKitFrame(forAXFrame: target, display: display), tolerance: 0.5) else {
                return (false, "display topology reflow AppKit frame mismatch for \(live.id.description)")
            }
            let serverFrame = LiveWindowServerVerification.waitForFrame(
                windowNumber: live.window.windowNumber,
                matching: target,
                tolerance: 0.5
            )
            guard serverFrame?.matches(target, tolerance: 0.5) == true else {
                return (false, "display topology reflow WindowServer frame mismatch for \(live.id.description)")
            }
        }

        let targets = [
            FocusBorderTarget(window: first.metadata, frame: firstTarget),
            FocusBorderTarget(window: second.metadata, frame: secondTarget)
        ]
        let rendered = overlay.render(OverlayModel.empty.settingTiledBorders(targets))
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        guard rendered.staleTiledBorderTargets.isEmpty,
              Set(overlay.debugTiledBorderWindowIDs()) == Set([first.id, second.id])
        else {
            return (false, "display topology reflow did not render both tiled borders")
        }
        for target in targets {
            let expectedAppKitFrame = appKitFrame(forAXFrame: target.frame, display: display)
                .insetBy(dx: -1, dy: -1)
            guard overlay.debugTiledBorderFrame(for: target.windowID)?.matches(
                expectedAppKitFrame,
                tolerance: 0.5
            ) == true,
                overlay.debugTiledBorderIsVisuallyVisible(for: target.windowID),
                let borderNumber = overlay.debugTiledBorderWindowNumber(for: target.windowID)
            else {
                return (false, "display topology reflow border was hidden or misplaced for \(target.windowID.description)")
            }
            let expectedServerFrame = target.frame.insetBy(dx: -1, dy: -1)
            guard LiveWindowServerVerification.waitForFrame(
                windowNumber: borderNumber,
                matching: expectedServerFrame,
                tolerance: 0.5
            )?.matches(expectedServerFrame, tolerance: 0.5) == true else {
                return (false, "display topology reflow border was absent from WindowServer for \(target.windowID.description)")
            }
        }

        return (true, "display topology reflow moved two visible AppKit windows and borders onto the surviving display")
    }

    private static func stagedFrame(in visibleFrame: CGRect, leading: Bool) -> CGRect {
        let width = visibleFrame.width * 0.36
        let height = visibleFrame.height * 0.42
        return CGRect(
            x: leading ? visibleFrame.minX + 32 : visibleFrame.maxX - width - 32,
            y: visibleFrame.minY + 48,
            width: width,
            height: height
        )
    }

    private static func makeWindow(
        title: String,
        frame: CGRect,
        display: DisplayInfo,
        color: NSColor
    ) -> TopologyVerificationWindow {
        let window = NSWindow(
            contentRect: appKitFrame(forAXFrame: frame, display: display),
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
        window.orderFrontRegardless()
        let id = WindowID(raw: CGWindowID(window.windowNumber))
        return TopologyVerificationWindow(
            id: id,
            window: window,
            metadata: WindowMetadata(
                id: id,
                bundleID: BundleID(raw: "dev.narwhal.display-topology-verifier"),
                title: title,
                role: "AXWindow",
                pid: getpid(),
                frame: frame,
                isResizable: true,
                isMinimized: false
            )
        )
    }

    private static func setAXFrame(_ window: NSWindow, to frame: CGRect, display: DisplayInfo) {
        window.setFrame(appKitFrame(forAXFrame: frame, display: display), display: true)
    }

    private static func appKitFrame(forAXFrame frame: CGRect, display: DisplayInfo) -> CGRect {
        let screenFrame = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == display.id.raw
        }?.frame ?? display.frame
        return CGRect(
            x: screenFrame.minX + (frame.minX - display.frame.minX),
            y: screenFrame.minY + (display.frame.maxY - frame.maxY),
            width: frame.width,
            height: frame.height
        )
    }
}

@MainActor
private struct TopologyVerificationWindow {
    let id: WindowID
    let window: NSWindow
    let metadata: WindowMetadata
}

private extension CGRect {
    func matches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        narwhalApproximatelyEquals(other, tolerance: tolerance)
    }
}
#endif
