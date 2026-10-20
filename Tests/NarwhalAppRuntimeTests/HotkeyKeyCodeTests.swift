import Carbon
import NarwhalCore
import Testing
@testable import NarwhalAppRuntime

@Suite("Hotkey key codes")
struct HotkeyKeyCodeTests {
    @Test("Every key name the config accepts maps to a key code without layout data")
    func everySupportedKeyMapsWithoutLayoutData() {
        let unmapped = HotkeyKeyNames.supported.filter {
            hotkeyKeyCode(for: $0, layoutKeyCodes: [:]) == nil
        }

        #expect(unmapped.isEmpty)
    }

    @Test("A character key resolves to the key that types it in the active layout")
    func characterKeyFollowsActiveLayout() {
        let azertyLikeLayout = ["a": UInt32(kVK_ANSI_Q)]

        #expect(hotkeyKeyCode(for: "a", layoutKeyCodes: azertyLikeLayout) == UInt32(kVK_ANSI_Q))
    }

    @Test("A character key missing from the layout falls back to its US position")
    func characterKeyFallsBackToUSPosition() {
        #expect(hotkeyKeyCode(for: "t", layoutKeyCodes: ["a": UInt32(kVK_ANSI_Q)]) == UInt32(kVK_ANSI_T))
    }

    @Test("Named keys use fixed key codes")
    func namedKeysUseFixedKeyCodes() {
        #expect(hotkeyKeyCode(for: "up", layoutKeyCodes: [:]) == UInt32(kVK_UpArrow))
        #expect(hotkeyKeyCode(for: "down", layoutKeyCodes: [:]) == UInt32(kVK_DownArrow))
        #expect(hotkeyKeyCode(for: "f5", layoutKeyCodes: [:]) == UInt32(kVK_F5))
        #expect(hotkeyKeyCode(for: "escape", layoutKeyCodes: [:]) == UInt32(kVK_Escape))
    }
}

/// Integration test: reads this machine's active keyboard layout.
@Suite("Keyboard layout (integration)")
struct KeyboardLayoutIntegrationTests {
    @Test("The active keyboard layout types every letter")
    func activeLayoutTypesEveryLetter() {
        let layoutKeyCodes = activeLayoutCharacterKeyCodes()

        #expect(Set("abcdefghijklmnopqrstuvwxyz".map(String.init)).isSubset(of: Set(layoutKeyCodes.keys)))
    }
}
