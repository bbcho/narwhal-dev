import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Overlay model")
struct OverlayModelTests {
    @Test("Focus border transitions preserve tiled border state")
    func focusBorderTransitionsPreserveTiledBorderState() {
        let tiled = target(1)
        let focused = target(2)
        let model = OverlayModel.empty
            .settingTiledBorders([tiled])
            .showingFocusBorder(focused)

        #expect(model.focusBorder == focused)
        #expect(model.tiledBorders == [tiled])

        let hidden = model.hidingFocusBorder()

        #expect(hidden.focusBorder == nil)
        #expect(hidden.tiledBorders == [tiled])
    }

    @Test("Removing a window clears only matching focus and tiled borders")
    func removingWindowClearsOnlyMatchingBorders() {
        let focused = target(3)
        let firstTiled = target(4)
        let secondTiled = target(5)
        let model = OverlayModel.empty
            .settingTiledBorders([firstTiled, secondTiled])
            .showingFocusBorder(focused)

        let withoutUnrelated = model.removingWindow(firstTiled.windowID)

        #expect(withoutUnrelated.focusBorder == focused)
        #expect(withoutUnrelated.tiledBorders == [secondTiled])

        let withoutFocused = withoutUnrelated.removingWindow(focused.windowID)

        #expect(withoutFocused.focusBorder == nil)
        #expect(withoutFocused.tiledBorders == [secondTiled])
    }

    @Test("Tiled borders are replaced and exposed in stable window order")
    func tiledBordersAreReplacedAndSorted() {
        let high = target(20)
        let low = target(10)
        let replacement = target(30)

        let initial = OverlayModel.empty.settingTiledBorders([high, low])

        #expect(initial.tiledBorders == [low, high])

        let model = initial.settingTiledBorders([replacement])

        #expect(model.tiledBorders == [replacement])
    }

    private func target(_ id: CGWindowID) -> FocusBorderTarget {
        FocusBorderTarget(
            windowID: WindowID(raw: id),
            frame: CGRect(x: CGFloat(id), y: 20, width: 300, height: 200),
            cornerRadius: 15
        )
    }
}
