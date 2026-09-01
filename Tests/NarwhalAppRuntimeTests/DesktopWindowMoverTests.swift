import CoreGraphics
import Foundation
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@Suite("Desktop window mover")
struct DesktopWindowMoverTests {
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
