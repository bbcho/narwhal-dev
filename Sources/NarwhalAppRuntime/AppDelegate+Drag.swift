import AppKit
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

extension AppDelegate {
    @MainActor
    func previewDragDrop(at location: CGPoint) {
        guard !isPaused else {
            overlay.hideDragPreview()
            return
        }
        guard let preview = dragPreview(at: location, displays: displayClient.currentDisplays()) else {
            overlay.hideDragPreview()
            return
        }
        overlay.showDragPreview(frame: preview.frame, title: preview.title, valid: preview.valid)
    }

    private func dragPreview(at location: CGPoint, displays: [DisplayID: DisplayInfo]) -> DragZonePreview? {
        guard let display = displays.values
            .filter({ AppDelegateGeometry.contains(location, in: $0.visibleFrame) })
            .sorted(by: { $0.id.raw < $1.id.raw })
            .first
        else {
            return nil
        }
        guard display.visibleFrame.width > 0, display.visibleFrame.height > 0 else { return nil }

        let proportional = CGPoint(
            x: (location.x - display.visibleFrame.minX) / display.visibleFrame.width,
            y: (location.y - display.visibleFrame.minY) / display.visibleFrame.height
        )
        let matches = config.zones.filter { AppDelegateGeometry.contains(proportional, in: $0.bounds) }
        guard matches.count == 1, let zone = matches.first else {
            if matches.count > 1 {
                return DragZonePreview(
                    frame: AppDelegateGeometry.badgeFrame(around: location),
                    title: "Overlapping zones",
                    valid: false
                )
            }
            return nil
        }

        return DragZonePreview(
            frame: AppDelegateGeometry.absoluteFrame(for: zone.bounds, in: display.visibleFrame),
            title: "Drop: \(AppDelegateText.dropActionDescription(zone.action))",
            valid: true
        )
    }

    /// Called synchronously on the first drag event of a modifier gesture: late
    /// enough that a clicked window has been activated, early enough that it
    /// has barely moved.
    @MainActor
    func recordDragStartWindow() {
        guard case .success(let snapshot) = axClient.focusedWindowSnapshot() else {
            dragStartWindow = nil
            return
        }
        dragStartWindow = DragStartWindow(windowID: snapshot.id, frame: snapshot.frame)
    }

    @MainActor
    func performDragDrop(at location: CGPoint, start: DragStartWindow?) async {
        overlay.hideDragPreview()
        guard !isPaused else {
            reporter.info("Drag drop ignored while Narwhal is paused")
            showOperatorFeedback("Narwhal paused", tone: .warning, showsHUD: false)
            return
        }
        let operation = "Drag drop"
        guard let context = await focusedLayoutContext(operation: operation) else { return }
        guard dragMovedWindow(from: start, to: DragStartWindow(windowID: context.id, frame: context.frame)) else {
            reporter.info("Drag drop ignored: the focused window did not move during the drag")
            return
        }
        let drag = DragEvent(windowID: context.id, location: location, displayID: nil)
        guard let command = resolveDrop(drag, zones: config.zones, displays: context.displays) else {
            reporter.info("Drag drop ignored: no matching exclusive zone at \(location.debugDescription)")
            showOperatorFeedback("No drop zone", tone: .warning)
            return
        }
        guard case .dropAtZone(let windowID, let displayID, let zoneID) = command else {
            reporter.error("Drag drop resolved to unsupported command: \(command)")
            return
        }

        reporter.info(
            "Drag drop resolved focused=\(context.id.description) display=\(displayID.raw) zone=\(zoneID.raw) location=\(location.debugDescription)"
        )
        guard await prepareLayoutWorld(context, displayID: displayID, operation: operation, refreshReason: "pre-drag drop") else { return }

        switch await worldActor.planDrop(windowID: windowID, displayID: displayID, zoneID: zoneID) {
        case .success(let result):
            _ = await applyPlannedDrop(result, windowID: windowID, displayID: displayID, zoneID: zoneID, retryOnClamp: true)
        case .failure(let error):
            reporter.error("Drag drop rejected by core: \(error.message)")
            showOperatorFeedback("Drag drop failed: \(error.message)", tone: .error)
        }
    }
}
