import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Focus border corner radius")
struct FocusBorderCornerRadiusTests {
    @Test("Standard resizable windows use the requested 15 point radius")
    func standardResizableWindowUsesFifteenPointRadius() {
        let radius = focusBorderCornerRadius(
            frame: CGRect(x: 0, y: 0, width: 900, height: 640),
            traits: .standard
        )

        #expect(radius == 15)
    }

    @Test("Dialogs and sheets use a smaller radius than standard windows")
    func dialogAndSheetUseSmallerRadiusThanStandardWindows() {
        let standard = focusBorderCornerRadius(
            frame: CGRect(x: 0, y: 0, width: 900, height: 640),
            traits: .standard
        )
        let dialog = focusBorderCornerRadius(
            frame: CGRect(x: 0, y: 0, width: 460, height: 260),
            traits: FocusBorderWindowTraits(
                role: "AXWindow",
                subrole: "AXDialog",
                isResizable: false,
                isFullscreen: false
            )
        )
        let sheet = focusBorderCornerRadius(
            frame: CGRect(x: 0, y: 0, width: 520, height: 280),
            traits: FocusBorderWindowTraits(
                role: "AXSheet",
                subrole: "",
                isResizable: false,
                isFullscreen: false
            )
        )

        #expect(dialog == 13)
        #expect(sheet == 13)
        #expect(dialog < standard)
    }

    @Test("Floating and non-resizable windows use compact radii")
    func floatingAndNonResizableWindowsUseCompactRadii() {
        let floating = focusBorderCornerRadius(
            frame: CGRect(x: 0, y: 0, width: 360, height: 240),
            traits: FocusBorderWindowTraits(
                role: "AXWindow",
                subrole: "AXFloatingWindow",
                isResizable: false,
                isFullscreen: false
            )
        )
        let nonResizable = focusBorderCornerRadius(
            frame: CGRect(x: 0, y: 0, width: 500, height: 360),
            traits: FocusBorderWindowTraits(
                role: "AXWindow",
                subrole: "AXStandardWindow",
                isResizable: false,
                isFullscreen: false
            )
        )

        #expect(floating == 10)
        #expect(nonResizable == 11)
    }

    @Test("Fullscreen and invalid geometry produce no corner radius")
    func fullscreenAndInvalidGeometryProduceNoCornerRadius() {
        let fullscreen = focusBorderCornerRadius(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            traits: FocusBorderWindowTraits(
                role: "AXWindow",
                subrole: "AXStandardWindow",
                isResizable: true,
                isFullscreen: true
            )
        )
        let invalid = focusBorderCornerRadius(
            frame: CGRect(x: 0, y: 0, width: 0, height: 900),
            traits: .standard
        )

        #expect(fullscreen == 0)
        #expect(invalid == 0)
    }

    @Test("Tiny windows clamp radius to half the smallest dimension")
    func tinyWindowsClampRadiusToHalfSmallestDimension() {
        let frame = CGRect(x: 0, y: 0, width: 24, height: 18)

        let radius = focusBorderCornerRadius(frame: frame, traits: .standard)

        #expect(radius == 8)
        #expect(radius <= Double(min(frame.width, frame.height)) / 2)
    }
}
