import CoreGraphics

public struct Config: Equatable, Sendable {
    public let keymap: [HotkeyBinding]
    public let rules: [WindowRule]
    public let zones: [Zone]
    public let gaps: Gaps
    public let border: BorderConfig
    public let hud: HUDConfig
    public let dragModifier: ModifierSet

    public init(
        keymap: [HotkeyBinding],
        rules: [WindowRule],
        zones: [Zone],
        gaps: Gaps,
        border: BorderConfig,
        hud: HUDConfig,
        dragModifier: ModifierSet
    ) {
        self.keymap = keymap
        self.rules = rules
        self.zones = zones
        self.gaps = gaps
        self.border = border
        self.hud = hud
        self.dragModifier = dragModifier
    }

    public static let `default` = Config(
        keymap: DefaultKeymap.entries,
        rules: [],
        zones: DefaultZones.entries,
        gaps: Gaps(inner: 0, outer: Insets(top: 0, left: 0, bottom: 0, right: 0)),
        border: .default,
        hud: .default,
        dragModifier: [.shift]
    )
}

public struct HotkeyBinding: Equatable, Sendable {
    public let key: KeySpec
    public let action: HotkeyAction

    public init(key: KeySpec, action: HotkeyAction) {
        self.key = key
        self.action = action
    }
}

public enum HotkeyAction: Equatable, Sendable {
    case command(CommandTemplate)
    case reloadConfig
}

public enum CommandTemplate: Equatable, Sendable {
    case push(Direction)
    case center
    case eject
    case focusDirection(Direction)
    case toggleFloat
    case resetLayout
}

public struct WindowRule: Equatable, Codable, Sendable {
    public let predicate: RulePredicate
    public let action: RuleAction

    public init(predicate: RulePredicate, action: RuleAction) {
        self.predicate = predicate
        self.action = action
    }
}

public indirect enum RulePredicate: Equatable, Codable, Sendable {
    case bundleID(String)
    case bundleIDMatches(regex: String)
    case role(String)
    case titleMatches(regex: String)
    case and([RulePredicate])
    case or([RulePredicate])
    case not(RulePredicate)
}

public enum RuleAction: Equatable, Codable, Sendable {
    case forceFloat
    case ignore
    case pinToDisplay(slot: Int)
}

public enum WindowOpenDecision: Equatable, Sendable {
    case tileOrFloatByDefault(WindowMetadata)
    case forceFloat(WindowMetadata)
    case ignore(WindowID)
    case pinToDisplay(WindowMetadata, slot: Int)
}

public struct Zone: Equatable, Sendable {
    public let id: ZoneID
    public let bounds: ProportionalRect
    public let action: ZoneAction

    public init(id: ZoneID, bounds: ProportionalRect, action: ZoneAction) {
        self.id = id
        self.bounds = bounds
        self.action = action
    }
}

public struct ZoneID: Hashable, Codable, Sendable {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }
}

public struct ProportionalRect: Equatable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public enum ZoneAction: Equatable, Codable, Sendable {
    case insertAsHalf(Direction)
    case insertAsQuarter(corner: Corner)
    case insertAsCenter
    case insertAtSubtree(NodePath)
}

public enum Corner: String, Codable, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

public enum DefaultKeymap {
    public static let entries: [HotkeyBinding] = [
        HotkeyBinding(key: KeySpec(key: "h", modifiers: [.control, .option]), action: .command(.push(.left))),
        HotkeyBinding(key: KeySpec(key: "l", modifiers: [.control, .option]), action: .command(.push(.right))),
        HotkeyBinding(key: KeySpec(key: "k", modifiers: [.control, .option]), action: .command(.push(.up))),
        HotkeyBinding(key: KeySpec(key: "j", modifiers: [.control, .option]), action: .command(.push(.down))),
        HotkeyBinding(key: KeySpec(key: "delete", modifiers: [.control, .option]), action: .command(.resetLayout))
    ]
}

public enum DefaultZones {
    public static let entries: [Zone] = [
        Zone(id: ZoneID(raw: "left-half"), bounds: ProportionalRect(x: 0, y: 0.30, w: 0.20, h: 0.40), action: .insertAsHalf(.left)),
        Zone(id: ZoneID(raw: "right-half"), bounds: ProportionalRect(x: 0.80, y: 0.30, w: 0.20, h: 0.40), action: .insertAsHalf(.right)),
        Zone(id: ZoneID(raw: "top-half"), bounds: ProportionalRect(x: 0.30, y: 0, w: 0.40, h: 0.20), action: .insertAsHalf(.up)),
        Zone(id: ZoneID(raw: "bottom-half"), bounds: ProportionalRect(x: 0.30, y: 0.80, w: 0.40, h: 0.20), action: .insertAsHalf(.down)),
        Zone(id: ZoneID(raw: "center"), bounds: ProportionalRect(x: 0.40, y: 0.40, w: 0.20, h: 0.20), action: .insertAsCenter)
    ]
}

public enum DefaultConfigLua {
    public static func render(_ config: Config = .default) -> String {
        """
        -- Bundled default configuration.
        -- Swift Config.default is canonical until the Lua loader lands.
        return {
          keymap = {
        \(renderKeymap(config.keymap))
          },
          gaps = {
            inner = \(number(config.gaps.inner)),
            outer = { top = \(number(config.gaps.outer.top)), left = \(number(config.gaps.outer.left)), bottom = \(number(config.gaps.outer.bottom)), right = \(number(config.gaps.outer.right)) },
          },
          drag_modifier = \(renderModifiers(config.dragModifier)),
          zones = {
        \(renderZones(config.zones))
          },
          border = { width = \(number(config.border.width)), color = \(quoted(config.border.colorHex)) },
          hud = { enabled = \(config.hud.enabled ? "true" : "false"), duration_millis = \(config.hud.durationMillis) },
          rules = {},
        }
        """ + "\n"
    }

    private static func renderKeymap(_ bindings: [HotkeyBinding]) -> String {
        bindings.map { binding in
            "    { key = \(quoted(binding.key.key)), modifiers = \(renderModifiers(binding.key.modifiers)), action = \(renderAction(binding.action)) },"
        }.joined(separator: "\n")
    }

    private static func renderAction(_ action: HotkeyAction) -> String {
        switch action {
        case .command(let template):
            return renderTemplate(template)
        case .reloadConfig:
            return "{ type = \"reload_config\" }"
        }
    }

    private static func renderTemplate(_ template: CommandTemplate) -> String {
        switch template {
        case .push(let direction):
            return "{ type = \"push\", direction = \(quoted(direction.rawValue)) }"
        case .center:
            return "{ type = \"center\" }"
        case .eject:
            return "{ type = \"eject\" }"
        case .focusDirection(let direction):
            return "{ type = \"focus_direction\", direction = \(quoted(direction.rawValue)) }"
        case .toggleFloat:
            return "{ type = \"toggle_float\" }"
        case .resetLayout:
            return "{ type = \"reset_layout\" }"
        }
    }

    private static func renderZones(_ zones: [Zone]) -> String {
        zones.map { zone in
            let bounds = zone.bounds
            return "    { id = \(quoted(zone.id.raw)), bounds = { x = \(number(bounds.x)), y = \(number(bounds.y)), w = \(number(bounds.w)), h = \(number(bounds.h)) }, action = \(renderZoneAction(zone.action)) },"
        }.joined(separator: "\n")
    }

    private static func renderZoneAction(_ action: ZoneAction) -> String {
        switch action {
        case .insertAsHalf(let direction):
            return "{ type = \"insert_as_half\", direction = \(quoted(direction.rawValue)) }"
        case .insertAsQuarter(let corner):
            return "{ type = \"insert_as_quarter\", corner = \(quoted(corner.rawValue)) }"
        case .insertAsCenter:
            return "{ type = \"insert_as_center\" }"
        case .insertAtSubtree(let path):
            return "{ type = \"insert_at_subtree\", path = { \(path.map(String.init).joined(separator: ", ")) } }"
        }
    }

    private static func renderModifiers(_ modifiers: ModifierSet) -> String {
        let values: [String] = [
            modifiers.contains(.control) ? quoted("control") : nil,
            modifiers.contains(.option) ? quoted("option") : nil,
            modifiers.contains(.shift) ? quoted("shift") : nil,
            modifiers.contains(.command) ? quoted("command") : nil
        ].compactMap { $0 }

        return "{ \(values.joined(separator: ", ")) }"
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else {
            preconditionFailure("Default config contains non-finite number")
        }
        return value.rounded() == value ? String(Int(value)) : String(value)
    }
}
