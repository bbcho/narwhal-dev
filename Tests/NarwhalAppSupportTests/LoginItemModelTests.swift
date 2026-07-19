import Testing
@testable import NarwhalAppSupport

@Suite("Login item presentation")
struct LoginItemModelTests {
    @Test("Enabled and disabled states use one stable checkable title")
    func stableToggleTitle() {
        #expect(LoginItemStatus.enabled.menuTitle == "Launch at Login")
        #expect(LoginItemStatus.disabled.menuTitle == "Launch at Login")
        #expect(LoginItemStatus.enabled.isEnabled)
        #expect(LoginItemStatus.disabled.isEnabled == false)
    }

    @Test("Approval and failure states remain actionable")
    func recoveryStates() {
        #expect(LoginItemStatus.requiresApproval.menuTitle.contains("Approval Required"))
        #expect(LoginItemStatus.requiresApproval.canPerformAction)
        #expect(LoginItemStatus.failed("denied").canPerformAction)
        #expect(LoginItemStatus.unavailable.canPerformAction == false)
    }
}
