import Foundation
import Testing
@testable import WinMgrCore

@Suite("Default config")
struct ConfigTests {
    @Test("Default keymap contains only implemented MVP hotkeys")
    func defaultKeymapContainsOnlyMvpHotkeys() {
        #expect(Config.default.keymap == [
            HotkeyBinding(key: KeySpec(key: "h", modifiers: [.control, .option]), action: .command(.focusDirection(.left))),
            HotkeyBinding(key: KeySpec(key: "l", modifiers: [.control, .option]), action: .command(.focusDirection(.right))),
            HotkeyBinding(key: KeySpec(key: "k", modifiers: [.control, .option]), action: .command(.focusDirection(.up))),
            HotkeyBinding(key: KeySpec(key: "j", modifiers: [.control, .option]), action: .command(.focusDirection(.down))),
            HotkeyBinding(key: KeySpec(key: "u", modifiers: [.control, .option]), action: .command(.focusCycle(.previous))),
            HotkeyBinding(key: KeySpec(key: "i", modifiers: [.control, .option]), action: .command(.focusCycle(.next))),
            HotkeyBinding(key: KeySpec(key: "h", modifiers: [.control, .option, .command]), action: .command(.push(.left))),
            HotkeyBinding(key: KeySpec(key: "l", modifiers: [.control, .option, .command]), action: .command(.push(.right))),
            HotkeyBinding(key: KeySpec(key: "k", modifiers: [.control, .option, .command]), action: .command(.push(.up))),
            HotkeyBinding(key: KeySpec(key: "j", modifiers: [.control, .option, .command]), action: .command(.push(.down))),
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

    @Test("Lua config data parses to the exact default Config value")
    func luaConfigDataParsesToDefaultConfig() throws {
        guard case .success(let config) = parseConfig(defaultLuaConfigData()) else {
            Issue.record("Expected default LuaConfigData to parse")
            return
        }

        #expect(config == Config.default)
    }

    @Test("Lua config parser accepts explicit startup keymap and gaps")
    func luaConfigParserAcceptsStartupKeymapAndGaps() throws {
        let customKeymap = [
            HotkeyBinding(key: KeySpec(key: "h", modifiers: [.control, .shift]), action: .command(.push(.left))),
            HotkeyBinding(key: KeySpec(key: "l", modifiers: [.control, .shift]), action: .command(.push(.right))),
            HotkeyBinding(key: KeySpec(key: "delete", modifiers: [.control, .shift]), action: .command(.resetLayout))
        ]
        let customGaps = Gaps(inner: 8, outer: Insets(top: 4, left: 6, bottom: 8, right: 10))

        var root = defaultLuaRoot()
        root["keymap"] = .array([
            binding(key: "h", modifiers: ["control", "shift"], action: ["type": .string("push"), "direction": .string("left")]),
            binding(key: "l", modifiers: ["control", "shift"], action: ["type": .string("push"), "direction": .string("right")]),
            binding(key: "delete", modifiers: ["control", "shift"], action: ["type": .string("reset_layout")])
        ])
        root["gaps"] = .table([
            "inner": .number(8),
            "outer": .table(["top": .number(4), "left": .number(6), "bottom": .number(8), "right": .number(10)])
        ])

        guard case .success(let config) = parseConfig(LuaConfigData(root: root)) else {
            Issue.record("Expected custom LuaConfigData to parse")
            return
        }

        #expect(config == Config(
            keymap: customKeymap,
            rules: [],
            zones: DefaultZones.entries,
            gaps: customGaps,
            border: .default,
            hud: .default,
            dragModifier: [.shift]
        ))
    }

    @Test("Lua config parser rejects duplicate hotkeys")
    func luaConfigParserRejectsDuplicateHotkeys() {
        var root = defaultLuaRoot()
        root["keymap"] = .array([
            binding(key: "h", modifiers: ["control", "option"], action: ["type": .string("push"), "direction": .string("left")]),
            binding(key: "h", modifiers: ["control", "option"], action: ["type": .string("push"), "direction": .string("right")])
        ])

        #expect(parseConfig(LuaConfigData(root: root)) == .failure(
            .invalidValue(key: "keymap[1]", reason: "duplicate hotkey")
        ))
    }

    @Test("Lua config parser rejects zone bounds outside the display")
    func luaConfigParserRejectsInvalidZoneBounds() {
        var root = defaultLuaRoot()
        root["zones"] = .array([
            .table([
                "id": .string("bad"),
                "bounds": .table(["x": .number(0.9), "y": .number(0), "w": .number(0.2), "h": .number(0.5)]),
                "action": .table(["type": .string("insert_as_half"), "direction": .string("right")])
            ])
        ])

        #expect(parseConfig(LuaConfigData(root: root)) == .failure(
            .invalidValue(key: "zones[1].bounds", reason: "bounds must fit inside the display")
        ))
    }

    @Test("Lua config parser rejects non-empty rules until rules are implemented")
    func luaConfigParserRejectsNonEmptyRules() {
        var root = defaultLuaRoot()
        root["rules"] = .array([.table(["predicate": .string("placeholder")])])

        #expect(parseConfig(LuaConfigData(root: root)) == .failure(
            .invalidValue(key: "rules", reason: "window rules are not implemented by the startup loader")
        ))
    }

    private func defaultLuaConfigData() -> LuaConfigData {
        LuaConfigData(root: defaultLuaRoot())
    }

    private func defaultLuaRoot() -> [String: LuaValue] {
        [
            "keymap": .array([
                binding(key: "h", modifiers: ["control", "option"], action: ["type": .string("focus_direction"), "direction": .string("left")]),
                binding(key: "l", modifiers: ["control", "option"], action: ["type": .string("focus_direction"), "direction": .string("right")]),
                binding(key: "k", modifiers: ["control", "option"], action: ["type": .string("focus_direction"), "direction": .string("up")]),
                binding(key: "j", modifiers: ["control", "option"], action: ["type": .string("focus_direction"), "direction": .string("down")]),
                binding(key: "u", modifiers: ["control", "option"], action: ["type": .string("focus_cycle"), "direction": .string("previous")]),
                binding(key: "i", modifiers: ["control", "option"], action: ["type": .string("focus_cycle"), "direction": .string("next")]),
                binding(key: "h", modifiers: ["control", "option", "command"], action: ["type": .string("push"), "direction": .string("left")]),
                binding(key: "l", modifiers: ["control", "option", "command"], action: ["type": .string("push"), "direction": .string("right")]),
                binding(key: "k", modifiers: ["control", "option", "command"], action: ["type": .string("push"), "direction": .string("up")]),
                binding(key: "j", modifiers: ["control", "option", "command"], action: ["type": .string("push"), "direction": .string("down")]),
                binding(key: "delete", modifiers: ["control", "option"], action: ["type": .string("reset_layout")])
            ]),
            "gaps": .table([
                "inner": .number(0),
                "outer": .table(["top": .number(0), "left": .number(0), "bottom": .number(0), "right": .number(0)])
            ]),
            "drag_modifier": .array([.string("shift")]),
            "zones": .array([
                zone(id: "left-half", x: 0, y: 0.30, w: 0.20, h: 0.40, action: ["type": .string("insert_as_half"), "direction": .string("left")]),
                zone(id: "right-half", x: 0.80, y: 0.30, w: 0.20, h: 0.40, action: ["type": .string("insert_as_half"), "direction": .string("right")]),
                zone(id: "top-half", x: 0.30, y: 0, w: 0.40, h: 0.20, action: ["type": .string("insert_as_half"), "direction": .string("up")]),
                zone(id: "bottom-half", x: 0.30, y: 0.80, w: 0.40, h: 0.20, action: ["type": .string("insert_as_half"), "direction": .string("down")]),
                zone(id: "center", x: 0.40, y: 0.40, w: 0.20, h: 0.20, action: ["type": .string("insert_as_center")])
            ]),
            "border": .table(["width": .number(2), "color": .string("#4DA3FF")]),
            "hud": .table(["enabled": .bool(true), "duration_millis": .number(700)]),
            "rules": .array([])
        ]
    }

    private func binding(key: String, modifiers: [String], action: [String: LuaValue]) -> LuaValue {
        .table([
            "key": .string(key),
            "modifiers": .array(modifiers.map(LuaValue.string)),
            "action": .table(action)
        ])
    }

    private func zone(id: String, x: Double, y: Double, w: Double, h: Double, action: [String: LuaValue]) -> LuaValue {
        .table([
            "id": .string(id),
            "bounds": .table(["x": .number(x), "y": .number(y), "w": .number(w), "h": .number(h)]),
            "action": .table(action)
        ])
    }
}
