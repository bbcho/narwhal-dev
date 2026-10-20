import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Vanished window model")
struct VanishedWindowModelTests {
    private let window = WindowID(raw: 5)

    @Test("A window the WindowServer no longer has was closed")
    func missingWindowWasClosed() {
        #expect(vanishedWindowFate(window, existingWindowIDs: [WindowID(raw: 6)], isMinimizedOrHidden: false) == .closed)
    }

    @Test("A window that still exists and is minimized or hidden is parked")
    func minimizedOrHiddenWindowIsParked() {
        #expect(vanishedWindowFate(window, existingWindowIDs: [window], isMinimizedOrHidden: true) == .parked)
    }

    @Test("A window that still exists but is neither minimized nor hidden went off screen")
    func existingVisibleElsewhereWindowWentOffscreen() {
        #expect(vanishedWindowFate(window, existingWindowIDs: [window], isMinimizedOrHidden: false) == .offscreen)
    }

    @Test("An unreadable window list never declares a window closed")
    func unreadableWindowListIsOffscreen() {
        #expect(vanishedWindowFate(window, existingWindowIDs: nil, isMinimizedOrHidden: false) == .offscreen)
    }
}
