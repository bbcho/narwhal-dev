import CoreGraphics
import Testing
@testable import NarwhalAppSupport

@Suite("Window resize eligibility model")
struct WindowResizeEligibilityModelTests {
    @Test("Standard AX windows remain eligible when AX size settable is unreliable")
    func standardAXWindowsRemainEligibleWhenAXSizeSettableIsUnreliable() {
        #expect(windowResizeEligibility(traits(
            subrole: "AXStandardWindow",
            axSizeAttributeSettable: false
        )))
        #expect(windowResizeEligibility(traits(
            subrole: "",
            axSizeAttributeSettable: false
        )))
    }

    @Test("Explicit AX size settable standard windows are eligible")
    func explicitAXSizeSettableStandardWindowsAreEligible() {
        #expect(windowResizeEligibility(traits(
            subrole: "AXStandardWindow",
            axSizeAttributeSettable: true
        )))
    }

    @Test("Nonstandard and unavailable windows are not eligible")
    func nonstandardAndUnavailableWindowsAreNotEligible() {
        #expect(!windowResizeEligibility(traits(subrole: "AXDialog", axSizeAttributeSettable: true)))
        #expect(!windowResizeEligibility(traits(subrole: "AXSheet", axSizeAttributeSettable: true)))
        #expect(!windowResizeEligibility(traits(subrole: "AXFloatingWindow", axSizeAttributeSettable: true)))
        #expect(!windowResizeEligibility(traits(role: "AXUnknown", subrole: "AXStandardWindow", axSizeAttributeSettable: true)))
        #expect(!windowResizeEligibility(traits(subrole: "AXStandardWindow", axSizeAttributeSettable: true, isMinimized: true)))
        #expect(!windowResizeEligibility(traits(subrole: "AXStandardWindow", axSizeAttributeSettable: true, isFullscreen: true)))
        #expect(!windowResizeEligibility(traits(
            subrole: "AXStandardWindow",
            axSizeAttributeSettable: true,
            frame: CGRect(x: 0, y: 0, width: 0, height: 400)
        )))
    }

    private func traits(
        role: String = "AXWindow",
        subrole: String,
        axSizeAttributeSettable: Bool,
        isMinimized: Bool = false,
        isFullscreen: Bool = false,
        frame: CGRect = CGRect(x: 100, y: 120, width: 900, height: 700)
    ) -> WindowResizeEligibilityTraits {
        WindowResizeEligibilityTraits(
            role: role,
            subrole: subrole,
            axSizeAttributeSettable: axSizeAttributeSettable,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            frame: frame
        )
    }
}
