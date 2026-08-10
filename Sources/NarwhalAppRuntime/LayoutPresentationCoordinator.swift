import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

@MainActor
final class LayoutPresentationCoordinator {
    private let currentModel: @MainActor () -> OverlayModel
    private let publish: @MainActor (OverlayModel) -> Void
    private var affectedWindowIDs: Set<WindowID> = []
    private var removedTiledBorders: [WindowID: FocusBorderTarget] = [:]

    init(
        currentModel: @escaping @MainActor () -> OverlayModel,
        publish: @escaping @MainActor (OverlayModel) -> Void
    ) {
        self.currentModel = currentModel
        self.publish = publish
    }

    func begin(affectedWindowIDs: Set<WindowID>, source: FocusBorderTarget?) {
        self.affectedWindowIDs = affectedWindowIDs
        let current = currentModel()
        removedTiledBorders = current.tiledBordersByWindowID.filter {
            affectedWindowIDs.contains($0.key)
        }
        var model = current.removingTiledBorders(for: affectedWindowIDs)
        if let source {
            model = model.showingFocusBorder(source)
        } else {
            model = model.hidingFocusBorder()
        }
        publish(model)
    }

    func committed(
        _ commit: LayoutTransactionCommit,
        windows: [WindowID: WindowMetadata]
    ) {
        var model = currentModel().mergingTiledBorders(
            borderTargets(frames: commit.appliedFrames, windows: windows)
        )
        switch commit.focusUpdate {
        case .target(let windowID, let frame):
            model = model.showingFocusBorder(
                borderTarget(windowID: windowID, frame: frame, windows: windows, model: model)
            )
        case .clear:
            model = model.hidingFocusBorder()
        case nil:
            break
        }
        affectedWindowIDs = []
        removedTiledBorders = [:]
        publish(model)
    }

    func rolledBack(
        frames: [WindowID: CGRect],
        windows: [WindowID: WindowMetadata]
    ) {
        let restoredFrames = frames.filter { affectedWindowIDs.contains($0.key) }
        let restored = removedTiledBorders.merging(
            Dictionary(
                uniqueKeysWithValues: borderTargets(frames: restoredFrames, windows: windows)
                    .map { ($0.windowID, $0) }
            )
        ) { _, verified in verified }
        var model = currentModel().mergingTiledBorders(Array(restored.values))
        if let focused = model.focusBorder,
           let restoredFrame = restoredFrames[focused.windowID] {
            model = model.showingFocusBorder(
                borderTarget(
                    windowID: focused.windowID,
                    frame: restoredFrame,
                    windows: windows,
                    model: model
                )
            )
        }
        affectedWindowIDs = []
        removedTiledBorders = [:]
        publish(model)
    }

    func reconciliationRequired(affectedWindowIDs: Set<WindowID>) {
        var model = currentModel().removingTiledBorders(for: affectedWindowIDs)
        if let focused = model.focusBorder,
           affectedWindowIDs.contains(focused.windowID) {
            model = model.hidingFocusBorder()
        }
        self.affectedWindowIDs = []
        removedTiledBorders = [:]
        publish(model)
    }

    private func borderTargets(
        frames: [WindowID: CGRect],
        windows: [WindowID: WindowMetadata]
    ) -> [FocusBorderTarget] {
        frames.keys.sorted(by: { $0.raw < $1.raw }).compactMap { windowID in
            guard let frame = frames[windowID] else { return nil }
            return borderTarget(
                windowID: windowID,
                frame: frame,
                windows: windows,
                model: currentModel()
            )
        }
    }

    private func borderTarget(
        windowID: WindowID,
        frame: CGRect,
        windows: [WindowID: WindowMetadata],
        model: OverlayModel
    ) -> FocusBorderTarget {
        if let window = windows[windowID] {
            return FocusBorderTarget(window: window, frame: frame)
        }
        let existing = model.tiledBordersByWindowID[windowID]
            ?? (model.focusBorder?.windowID == windowID ? model.focusBorder : nil)
        return FocusBorderTarget(
            windowID: windowID,
            frame: frame,
            cornerRadius: existing?.cornerRadius ?? 0
        )
    }
}
