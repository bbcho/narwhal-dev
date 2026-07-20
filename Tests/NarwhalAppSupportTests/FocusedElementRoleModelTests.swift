import NarwhalAppSupport
import Testing

@Suite("Focused element window roles")
struct FocusedElementRoleModelTests {
    @Test("Windows, sheets, and dialogs terminate focused-element ancestry")
    func windowContainers() {
        #expect(isFocusedWindowContainer(role: "AXWindow", subrole: "AXStandardWindow"))
        #expect(isFocusedWindowContainer(role: "AXSheet", subrole: ""))
        #expect(isFocusedWindowContainer(role: "AXDialog", subrole: ""))
        #expect(isFocusedWindowContainer(role: "AXWindow", subrole: "AXDialog"))
        #expect(isFocusedWindowContainer(role: "AXWindow", subrole: "AXSystemDialog"))
    }

    @Test("Controls and groups do not terminate focused-element ancestry")
    func nonWindowContainers() {
        #expect(!isFocusedWindowContainer(role: "AXButton", subrole: ""))
        #expect(!isFocusedWindowContainer(role: "AXGroup", subrole: ""))
        #expect(!isFocusedWindowContainer(role: "AXTextField", subrole: "AXSearchField"))
    }

    @Test("Only modal dialog containers override a focused control's parent window")
    func transientWindowPrecedence() {
        #expect(isTransientFocusedWindow(role: "AXSheet", subrole: ""))
        #expect(isTransientFocusedWindow(role: "AXWindow", subrole: "AXDialog"))
        #expect(isTransientFocusedWindow(role: "AXWindow", subrole: "AXSystemDialog"))
        #expect(!isTransientFocusedWindow(role: "AXWindow", subrole: "AXStandardWindow"))
    }
}
