import CoreGraphics
import NarwhalAppSupport
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("Layout presentation coordinator")
struct LayoutPresentationCoordinatorTests {
    @Test("A transaction hides only affected tiled borders and anchors focus to the live source frame")
    func beginUsesLiveSourceAndPreservesUnrelatedBorders() {
        let store = PresentationStore(model: OverlayModel(
            focusBorder: target(1, x: 10),
            tiledBorders: [target(1, x: 10), target(2, x: 500)]
        ))
        let coordinator = store.coordinator()
        let liveSource = target(1, x: 24)

        coordinator.begin(affectedWindowIDs: [WindowID(raw: 1)], source: liveSource)

        #expect(store.model.focusBorder == liveSource)
        #expect(store.model.tiledBorders == [target(2, x: 500)])
        #expect(store.publications.count == 1)
    }

    @Test("Commit publishes verified frames and the verified focus target")
    func commitPublishesVerifiedFrames() {
        let store = PresentationStore(model: OverlayModel(
            focusBorder: target(1, x: 10),
            tiledBorders: [target(1, x: 10), target(2, x: 500)]
        ))
        let coordinator = store.coordinator()
        coordinator.begin(affectedWindowIDs: [WindowID(raw: 1)], source: target(1, x: 10))
        let verified = CGRect(x: 32, y: 40, width: 456, height: 700)

        coordinator.committed(
            LayoutTransactionCommit(
                appliedFrames: [WindowID(raw: 1): verified],
                focusUpdate: .target(windowID: WindowID(raw: 1), frame: verified),
                affectedWorkspaces: []
            ),
            windows: [WindowID(raw: 1): metadata(1)]
        )

        #expect(store.model.tiledBordersByWindowID[WindowID(raw: 1)]?.frame == verified)
        #expect(store.model.tiledBordersByWindowID[WindowID(raw: 2)] == target(2, x: 500))
        #expect(store.model.focusBorder?.frame == verified)
        #expect(store.publications.count == 2)
    }

    @Test("Rollback republishes original frames for affected windows")
    func rollbackRestoresOriginalFrames() {
        let store = PresentationStore(model: OverlayModel(
            focusBorder: target(1, x: 10),
            tiledBorders: [target(1, x: 10), target(2, x: 500)]
        ))
        let coordinator = store.coordinator()
        coordinator.begin(affectedWindowIDs: [WindowID(raw: 1)], source: target(1, x: 24))
        let original = CGRect(x: 10, y: 40, width: 480, height: 700)

        coordinator.rolledBack(
            frames: [WindowID(raw: 1): original],
            windows: [WindowID(raw: 1): metadata(1)]
        )

        #expect(store.model.tiledBordersByWindowID[WindowID(raw: 1)]?.frame == original)
        #expect(store.model.focusBorder?.frame == original)
        #expect(store.model.tiledBordersByWindowID[WindowID(raw: 2)] == target(2, x: 500))
    }

    @Test("Reconciliation keeps affected borders absent")
    func reconciliationDoesNotPublishUnverifiedFrames() {
        let store = PresentationStore(model: OverlayModel(
            focusBorder: target(1, x: 10),
            tiledBorders: [target(1, x: 10), target(2, x: 500)]
        ))
        let coordinator = store.coordinator()
        coordinator.begin(affectedWindowIDs: [WindowID(raw: 1)], source: target(1, x: 24))

        coordinator.reconciliationRequired(affectedWindowIDs: [WindowID(raw: 1)])

        #expect(store.model.focusBorder == nil)
        #expect(store.model.tiledBorders == [target(2, x: 500)])
    }

    private func target(_ id: CGWindowID, x: CGFloat) -> FocusBorderTarget {
        FocusBorderTarget(
            windowID: WindowID(raw: id),
            frame: CGRect(x: x, y: 40, width: 400, height: 700),
            cornerRadius: 12
        )
    }

    private func metadata(_ id: CGWindowID) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: id),
            bundleID: BundleID(raw: "test.app"),
            title: "Window \(id)",
            role: "AXWindow",
            pid: 100,
            frame: .zero,
            isResizable: true,
            isMinimized: false
        )
    }
}

@MainActor
private final class PresentationStore {
    var model: OverlayModel
    var publications: [OverlayModel] = []

    init(model: OverlayModel) {
        self.model = model
    }

    func coordinator() -> LayoutPresentationCoordinator {
        LayoutPresentationCoordinator(
            currentModel: { [weak self] in self?.model ?? .empty },
            publish: { [weak self] model in
                self?.model = model
                self?.publications.append(model)
            }
        )
    }
}
