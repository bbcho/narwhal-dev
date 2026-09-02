import CoreGraphics
import Foundation
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@Suite("Desktop window mover")
struct DesktopWindowMoverTests {
    @Test("Desktop drag point sits beside the rightmost window control")
    func desktopDragPointSitsBesideRightmostWindowControl() {
        let windowFrame = CGRect(x: 100, y: 90, width: 1_000, height: 800)
        let controlFrames = [
            CGRect(x: 112, y: 110, width: 14, height: 14),
            CGRect(x: 132, y: 110, width: 14, height: 14),
            CGRect(x: 152, y: 110, width: 14, height: 14),
        ]

        let point = desktopWindowDragPoint(
            windowFrame: windowFrame,
            controlFrames: controlFrames
        )

        #expect(point == CGPoint(x: 174, y: 117))
    }

    @Test("Window controls outside the title bar cannot produce a desktop drag point")
    func controlsOutsideTitleBarAreRejected() {
        let point = desktopWindowDragPoint(
            windowFrame: CGRect(x: 100, y: 90, width: 1_000, height: 800),
            controlFrames: [CGRect(x: 112, y: 300, width: 14, height: 14)]
        )

        #expect(point == nil)
    }

    @Test("Desktop drag offset remains valid when the window moves after preflight")
    func desktopDragOffsetSurvivesWindowMovement() {
        let offset = desktopWindowDragOffset(
            windowFrame: CGRect(x: 100, y: 90, width: 1_000, height: 800),
            controlFrames: [CGRect(x: 152, y: 110, width: 14, height: 14)]
        )

        #expect(offset == CGVector(dx: 74, dy: 27))
        #expect(offset.map { CGPoint(x: 1_200 + $0.dx, y: 400 + $0.dy) } == CGPoint(x: 1_274, y: 427))
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
