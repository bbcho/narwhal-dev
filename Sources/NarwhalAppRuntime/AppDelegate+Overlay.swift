import AppKit
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

extension AppDelegate {
    func reportFocusedWindowSnapshot() -> FocusedWindowSnapshot? {
        switch axClient.focusedWindowSnapshot() {
        case .success(let snapshot):
            reporter.info("Focused window: \(snapshot.logDescription)")
            updateOperatingStatus { $0.focusedWindowID = snapshot.id }
            return snapshot
        case .failure(let error):
            reporter.error("Focused-window snapshot failed: \(error.description)")
            showOperatorFeedback("Focused window unavailable", tone: .warning, showsHUD: false)
            return nil
        }
    }

    @MainActor
    func updateFocusBorder(for snapshot: FocusedWindowSnapshot) {
        if snapshot.isFullscreen {
            setFocusBorder(nil)
        } else {
            setFocusBorder(snapshot.focusBorderTarget)
        }
    }

    @MainActor
    func updateFocusBorderFromWorld(windowID: WindowID) async {
        switch await worldActor.planFocus(windowID) {
        case .success(let result):
            setFocusBorder(FocusBorderTarget(window: result.window, frame: result.frame))
        case .failure(let error):
            reporter.error("Focus border refresh failed: \(error.message)")
        }
    }

    @MainActor
    func setFocusBorder(_ target: FocusBorderTarget?) {
        if let target {
            publishOverlayModel(overlayModel.showingFocusBorder(target))
        } else {
            publishOverlayModel(overlayModel.hidingFocusBorder())
        }
    }

    @MainActor
    func suppressFocusBorder(for windowID: WindowID, frame: CGRect) {
        overlayModel = overlayModel.hidingFocusBorder()
        overlay.suppressFocusBorder(for: windowID, frame: frame)
        overlay.render(overlayModel)
    }

    @MainActor
    func setTiledBorders(_ targets: [FocusBorderTarget]) {
        publishOverlayModel(overlayModel.settingTiledBorders(targets))
    }

    @MainActor
    func publishOverlayModel(_ model: OverlayModel) {
        overlayModel = model
        let renderResult = overlay.render(model)
        for windowID in renderResult.staleTiledBorderTargets {
            reporter.info("Tiled border target \(windowID.description) did not match live WindowServer bounds; scheduling environment refresh")
            scheduleCoalescedEnvironmentRefresh(.tiledBorderTargetMismatch(windowID))
        }
    }

    @MainActor
    func clearBorderOverlays() {
        publishOverlayModel(.empty)
    }

    @MainActor
    func removeWindowFromOverlays(_ windowID: WindowID) {
        publishOverlayModel(overlayModel.removingWindow(windowID))
    }

    private func focusBorderTarget(
        windowID: WindowID,
        frame: CGRect,
        windows: [WindowID: WindowMetadata]
    ) -> FocusBorderTarget {
        guard let window = windows[windowID] else {
            return FocusBorderTarget(windowID: windowID, frame: frame, traits: .standard)
        }
        return FocusBorderTarget(window: window, frame: frame)
    }

    @MainActor
    func updateTiledBordersFromWorld() async {
        switch await worldActor.tiledBorderTargets() {
        case .success(let targets):
            setTiledBorders(targets)
        case .failure(let error):
            reporter.error("Tiled border refresh failed: \(error.message)")
            setTiledBorders([])
        }
    }

    func refreshWorkspacePresentationSurfaces() async {
        let presentation = await worldActor.workbenchPresentation(
            snapshotQuality: operatingStatus.snapshotQuality
        )
        menubar.updateWorkspacePresentation(presentation)
        workbenchController.updatePresentationIfVisible(presentation)
    }
}
