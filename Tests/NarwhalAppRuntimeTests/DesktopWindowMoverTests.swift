import CoreGraphics
import Foundation
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@Suite("Desktop window mover")
struct DesktopWindowMoverTests {
    @Test("Desktop drag uses the measured gap between Close and Minimize")
    func desktopDragUsesControlGap() {
        #expect(desktopWindowDragPoint(
            windowFrame: CGRect(x: 100, y: 90, width: 1_000, height: 800),
            closeButtonFrame: CGRect(x: 111, y: 104, width: 16, height: 16),
            minimizeButtonFrame: CGRect(x: 134, y: 104, width: 16, height: 16)
        ) == CGPoint(x: 130.5, y: 112))
    }

    @Test("Missing safe gaps and controls outside the title bar are rejected",
          arguments: [CGRect(x: 100, y: 104, width: 16, height: 16),
                      CGRect(x: 126, y: 104, width: 16, height: 16),
                      CGRect(x: 129, y: 104, width: 16, height: 16),
                      CGRect(x: 134, y: 130, width: 16, height: 16),
                      CGRect(x: 134, y: 304, width: 16, height: 16),
                      CGRect.zero])
    func unsafeControlGapsAreRejected(minimize: CGRect) {
        #expect(desktopWindowDragPoint(
            windowFrame: CGRect(x: 100, y: 90, width: 1_000, height: 800),
            closeButtonFrame: CGRect(x: 111, y: 104, width: 16, height: 16),
            minimizeButtonFrame: minimize
        ) == nil)
    }

    @Test("The control gap translates across displays", arguments: [-2_000.0, 0, 1_500])
    func desktopDragPointTranslates(dx: CGFloat) {
        #expect(desktopWindowDragPoint(
            windowFrame: CGRect(x: dx, y: -500, width: 1_000, height: 800),
            closeButtonFrame: CGRect(x: dx + 11, y: -486, width: 16, height: 16),
            minimizeButtonFrame: CGRect(x: dx + 34, y: -486, width: 16, height: 16)
        ) == CGPoint(x: dx + 30.5, y: -478))
    }

    @Test("Desktop drag uses room on either side and retains a drag for full-width windows")
    func desktopDragRespectsHorizontalConstraints() {
        let visible = CGRect(x: 0, y: 30, width: 1_000, height: 800)
        #expect(desktopWindowDragVector(windowFrame: CGRect(x: 0, y: 30, width: 500, height: 500), visibleFrame: visible) == CGVector(dx: 18, dy: 0))
        #expect(desktopWindowDragVector(windowFrame: CGRect(x: 500, y: 30, width: 500, height: 500), visibleFrame: visible) == CGVector(dx: -18, dy: 0))
        #expect(desktopWindowDragVector(windowFrame: CGRect(x: 0, y: 30, width: 1_000, height: 500), visibleFrame: visible) == CGVector(dx: 18, dy: 0))
    }

    @Test("Configured desktop shortcut preserves command and Fn modifiers")
    func configuredShortcutPreservesModifiers() throws {
        let preferences: NSDictionary = [
            "79": [
                "enabled": true,
                "value": ["parameters": [65_535, 123, 9_437_184]]
            ]
        ]

        let shortcut = try desktopSwitchShortcut(for: .left, in: preferences).get()

        #expect(shortcut.keyCode == 123)
        #expect(shortcut.flags == [.maskCommand, .maskSecondaryFn])
    }

    @Test("Disabled desktop shortcut is rejected")
    func disabledShortcutIsRejected() {
        let preferences: NSDictionary = [
            "81": [
                "enabled": false,
                "value": ["parameters": [65_535, 124, 9_437_184]]
            ]
        ]

        #expect(desktopSwitchShortcut(for: .right, in: preferences) == .failure(.shortcutUnavailable(.right)))
    }
}
