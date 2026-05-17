import Foundation
import Testing
@testable import WinMgrCore

@Suite("Default config")
struct ConfigTests {
    @Test("Default keymap contains only implemented MVP hotkeys")
    func defaultKeymapContainsOnlyMvpHotkeys() {
        #expect(Config.default.keymap == [
            HotkeyBinding(key: KeySpec(key: "h", modifiers: [.control, .option]), action: .command(.push(.left))),
            HotkeyBinding(key: KeySpec(key: "l", modifiers: [.control, .option]), action: .command(.push(.right))),
            HotkeyBinding(key: KeySpec(key: "k", modifiers: [.control, .option]), action: .command(.push(.up))),
            HotkeyBinding(key: KeySpec(key: "j", modifiers: [.control, .option]), action: .command(.push(.down))),
            HotkeyBinding(key: KeySpec(key: "delete", modifiers: [.control, .option]), action: .command(.resetLayout))
        ])
    }

    @Test("Default keymap has no duplicate key specs")
    func defaultKeymapHasNoDuplicateKeys() {
        let keys = Config.default.keymap.map(\.key)
        for (index, key) in keys.enumerated() {
            #expect(!keys.dropFirst(index + 1).contains(key))
        }
    }

    @Test("Bundled init.lua exactly mirrors Swift Config.default")
    func bundledLuaMirrorsSwiftDefaultConfig() throws {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bundled = packageRoot.appendingPathComponent("DefaultConfig/init.lua")
        let content = try String(contentsOf: bundled, encoding: .utf8)

        #expect(content == DefaultConfigLua.render(.default))
    }
}
