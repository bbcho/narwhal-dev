public func parseConfig(_ data: LuaConfigData) -> Result<Config, ConfigError> {
    do {
        return .success(try ConfigParser(root: data.root).parse())
    } catch let error as ConfigError {
        return .failure(error)
    } catch {
        return .failure(.invalidValue(key: "root", reason: String(describing: error)))
    }
}

private struct ConfigParser {
    let root: [String: LuaValue]

    func parse() throws -> Config {
        let config = Config(
            keymap: try parseKeymap(required("keymap")),
            rules: try parseRules(required("rules")),
            zones: try parseZones(required("zones")),
            gaps: try parseGaps(required("gaps")),
            border: try parseBorder(required("border")),
            hud: try parseHUD(required("hud")),
            dragModifier: try parseModifiers(required("drag_modifier"), key: "drag_modifier")
        )
        try validateNoDuplicateHotkeys(config.keymap)
        return config
    }

    private func required(_ key: String) throws -> LuaValue {
        guard let value = root[key] else { throw ConfigError.missingKey(key) }
        return value
    }

    private func parseKeymap(_ value: LuaValue) throws -> [HotkeyBinding] {
        try array(value, key: "keymap").enumerated().map { index, item in
            let path = "keymap[\(index + 1)]"
            let table = try table(item, key: path)
            let key = try string(required("key", in: table, path: path), key: "\(path).key").lowercased()
            guard !key.isEmpty else {
                throw ConfigError.invalidValue(key: "\(path).key", reason: "key cannot be empty")
            }
            return HotkeyBinding(
                key: KeySpec(
                    key: key,
                    modifiers: try parseModifiers(required("modifiers", in: table, path: path), key: "\(path).modifiers")
                ),
                action: try parseHotkeyAction(required("action", in: table, path: path), key: "\(path).action")
            )
        }
    }

    private func parseHotkeyAction(_ value: LuaValue, key: String) throws -> HotkeyAction {
        let table = try table(value, key: key)
        let type = try string(required("type", in: table, path: key), key: "\(key).type")
        switch type {
        case "push":
            return .command(.push(try parseDirection(required("direction", in: table, path: key), key: "\(key).direction")))
        case "center":
            return .command(.center)
        case "eject":
            return .command(.eject)
        case "swap":
            return .command(.swap(try parseDirection(required("direction", in: table, path: key), key: "\(key).direction")))
        case "focus_direction":
            return .command(.focusDirection(try parseDirection(required("direction", in: table, path: key), key: "\(key).direction")))
        case "focus_cycle":
            return .command(.focusCycle(try parseFocusCycleDirection(required("direction", in: table, path: key), key: "\(key).direction")))
        case "toggle_float":
            return .command(.toggleFloat)
        case "balance":
            return .command(.balance)
        case "reset_layout":
            return .command(.resetLayout)
        case "reload_config":
            return .reloadConfig
        default:
            throw ConfigError.invalidValue(key: "\(key).type", reason: "unsupported action '\(type)'")
        }
    }

    private func parseRules(_ value: LuaValue) throws -> [WindowRule] {
        switch value {
        case .array(let values) where values.isEmpty:
            return []
        case .table(let values) where values.isEmpty:
            return []
        case .array(let values):
            return try values.enumerated().map { index, item in
                try parseRule(item, key: "rules[\(index + 1)]")
            }
        case .table:
            throw ConfigError.wrongType(key: "rules", expected: "array")
        default:
            throw ConfigError.wrongType(key: "rules", expected: "array")
        }
    }

    private func parseRule(_ value: LuaValue, key: String) throws -> WindowRule {
        let table = try table(value, key: key)
        return WindowRule(
            predicate: try parseRulePredicate(required("predicate", in: table, path: key), key: "\(key).predicate"),
            action: try parseRuleAction(required("action", in: table, path: key), key: "\(key).action")
        )
    }

    private func parseRulePredicate(_ value: LuaValue, key: String) throws -> RulePredicate {
        let table = try table(value, key: key)
        let type = try string(required("type", in: table, path: key), key: "\(key).type")
        switch type {
        case "bundle_id":
            return .bundleID(try nonEmptyString(required("value", in: table, path: key), key: "\(key).value"))
        case "bundle_id_matches":
            return .bundleIDMatches(regex: try regexPattern(required("pattern", in: table, path: key), key: "\(key).pattern"))
        case "role":
            return .role(try nonEmptyString(required("value", in: table, path: key), key: "\(key).value"))
        case "title_matches":
            return .titleMatches(regex: try regexPattern(required("pattern", in: table, path: key), key: "\(key).pattern"))
        case "and":
            let predicates = try parsePredicateArray(required("predicates", in: table, path: key), key: "\(key).predicates")
            guard !predicates.isEmpty else {
                throw ConfigError.invalidValue(key: "\(key).predicates", reason: "and predicates cannot be empty")
            }
            return .and(predicates)
        case "or":
            let predicates = try parsePredicateArray(required("predicates", in: table, path: key), key: "\(key).predicates")
            guard !predicates.isEmpty else {
                throw ConfigError.invalidValue(key: "\(key).predicates", reason: "or predicates cannot be empty")
            }
            return .or(predicates)
        case "not":
            return .not(try parseRulePredicate(required("predicate", in: table, path: key), key: "\(key).predicate"))
        default:
            throw ConfigError.invalidValue(key: "\(key).type", reason: "unsupported rule predicate '\(type)'")
        }
    }

    private func parsePredicateArray(_ value: LuaValue, key: String) throws -> [RulePredicate] {
        try array(value, key: key).enumerated().map { index, item in
            try parseRulePredicate(item, key: "\(key)[\(index + 1)]")
        }
    }

    private func parseRuleAction(_ value: LuaValue, key: String) throws -> RuleAction {
        let table = try table(value, key: key)
        let type = try string(required("type", in: table, path: key), key: "\(key).type")
        switch type {
        case "force_float":
            return .forceFloat
        case "ignore":
            return .ignore
        case "pin_to_display":
            return .pinToDisplay(slot: try nonNegativeInt(required("slot", in: table, path: key), key: "\(key).slot"))
        default:
            throw ConfigError.invalidValue(key: "\(key).type", reason: "unsupported rule action '\(type)'")
        }
    }

    private func parseZones(_ value: LuaValue) throws -> [Zone] {
        let zones = try array(value, key: "zones").enumerated().map { index, item in
            let path = "zones[\(index + 1)]"
            let table = try table(item, key: path)
            return Zone(
                id: ZoneID(raw: try string(required("id", in: table, path: path), key: "\(path).id")),
                bounds: try parseBounds(required("bounds", in: table, path: path), key: "\(path).bounds"),
                action: try parseZoneAction(required("action", in: table, path: path), key: "\(path).action")
            )
        }

        for (index, zone) in zones.enumerated() {
            guard !zone.id.raw.isEmpty else {
                throw ConfigError.invalidValue(key: "zones[\(index + 1)].id", reason: "zone id cannot be empty")
            }
            if zones.dropFirst(index + 1).contains(where: { $0.id == zone.id }) {
                throw ConfigError.invalidValue(key: "zones[\(index + 1)].id", reason: "duplicate zone id '\(zone.id.raw)'")
            }
        }
        return zones
    }

    private func parseBounds(_ value: LuaValue, key: String) throws -> ProportionalRect {
        let table = try table(value, key: key)
        let rect = ProportionalRect(
            x: try boundedNumber(required("x", in: table, path: key), key: "\(key).x", min: 0, max: 1),
            y: try boundedNumber(required("y", in: table, path: key), key: "\(key).y", min: 0, max: 1),
            w: try boundedNumber(required("w", in: table, path: key), key: "\(key).w", min: 0, max: 1),
            h: try boundedNumber(required("h", in: table, path: key), key: "\(key).h", min: 0, max: 1)
        )
        guard rect.w > 0, rect.h > 0 else {
            throw ConfigError.invalidValue(key: key, reason: "width and height must be positive")
        }
        guard rect.x + rect.w <= 1, rect.y + rect.h <= 1 else {
            throw ConfigError.invalidValue(key: key, reason: "bounds must fit inside the display")
        }
        return rect
    }

    private func parseZoneAction(_ value: LuaValue, key: String) throws -> ZoneAction {
        let table = try table(value, key: key)
        let type = try string(required("type", in: table, path: key), key: "\(key).type")
        switch type {
        case "insert_as_half":
            return .insertAsHalf(try parseDirection(required("direction", in: table, path: key), key: "\(key).direction"))
        case "insert_as_quarter":
            return .insertAsQuarter(corner: try parseCorner(required("corner", in: table, path: key), key: "\(key).corner"))
        case "insert_as_center":
            return .insertAsCenter
        case "insert_at_subtree":
            return .insertAtSubtree(try parseNodePath(required("path", in: table, path: key), key: "\(key).path"))
        default:
            throw ConfigError.invalidValue(key: "\(key).type", reason: "unsupported zone action '\(type)'")
        }
    }

    private func parseGaps(_ value: LuaValue) throws -> Gaps {
        let gapTable = try table(value, key: "gaps")
        let outer = try table(required("outer", in: gapTable, path: "gaps"), key: "gaps.outer")
        return Gaps(
            inner: try nonNegativeNumber(required("inner", in: gapTable, path: "gaps"), key: "gaps.inner"),
            outer: Insets(
                top: try nonNegativeNumber(required("top", in: outer, path: "gaps.outer"), key: "gaps.outer.top"),
                left: try nonNegativeNumber(required("left", in: outer, path: "gaps.outer"), key: "gaps.outer.left"),
                bottom: try nonNegativeNumber(required("bottom", in: outer, path: "gaps.outer"), key: "gaps.outer.bottom"),
                right: try nonNegativeNumber(required("right", in: outer, path: "gaps.outer"), key: "gaps.outer.right")
            )
        )
    }

    private func parseBorder(_ value: LuaValue) throws -> BorderConfig {
        let table = try table(value, key: "border")
        let color = try string(required("color", in: table, path: "border"), key: "border.color")
        guard isHexRGB(color) else {
            throw ConfigError.invalidValue(key: "border.color", reason: "expected #RRGGBB")
        }
        return BorderConfig(
            width: try nonNegativeNumber(required("width", in: table, path: "border"), key: "border.width"),
            colorHex: color
        )
    }

    private func parseHUD(_ value: LuaValue) throws -> HUDConfig {
        let table = try table(value, key: "hud")
        return HUDConfig(
            enabled: try bool(required("enabled", in: table, path: "hud"), key: "hud.enabled"),
            durationMillis: try nonNegativeInt(required("duration_millis", in: table, path: "hud"), key: "hud.duration_millis")
        )
    }

    private func parseModifiers(_ value: LuaValue, key: String) throws -> ModifierSet {
        var result = ModifierSet()
        let values = try array(value, key: key).enumerated()
        for (index, item) in values {
            let path = "\(key)[\(index + 1)]"
            let name = try string(item, key: path)
            let modifier = try modifier(named: name, key: path)
            guard !result.contains(modifier) else {
                throw ConfigError.invalidValue(key: path, reason: "duplicate modifier '\(name)'")
            }
            result.insert(modifier)
        }
        return result
    }

    private func parseDirection(_ value: LuaValue, key: String) throws -> Direction {
        let raw = try string(value, key: key)
        guard let direction = Direction(rawValue: raw) else {
            throw ConfigError.invalidValue(key: key, reason: "unsupported direction '\(raw)'")
        }
        return direction
    }

    private func parseFocusCycleDirection(_ value: LuaValue, key: String) throws -> FocusCycleDirection {
        let raw = try string(value, key: key)
        guard let direction = FocusCycleDirection(rawValue: raw) else {
            throw ConfigError.invalidValue(key: key, reason: "unsupported focus cycle direction '\(raw)'")
        }
        return direction
    }

    private func parseCorner(_ value: LuaValue, key: String) throws -> Corner {
        let raw = try string(value, key: key)
        guard let corner = Corner(rawValue: raw) else {
            throw ConfigError.invalidValue(key: key, reason: "unsupported corner '\(raw)'")
        }
        return corner
    }

    private func parseNodePath(_ value: LuaValue, key: String) throws -> NodePath {
        try array(value, key: key).enumerated().map { index, item in
            try nonNegativeInt(item, key: "\(key)[\(index + 1)]")
        }
    }

    private func validateNoDuplicateHotkeys(_ keymap: [HotkeyBinding]) throws {
        for (index, binding) in keymap.enumerated() {
            if keymap.dropFirst(index + 1).contains(where: { $0.key == binding.key }) {
                throw ConfigError.invalidValue(key: "keymap[\(index + 1)]", reason: "duplicate hotkey")
            }
        }
    }

    private func required(_ name: String, in table: [String: LuaValue], path: String) throws -> LuaValue {
        guard let value = table[name] else { throw ConfigError.missingKey("\(path).\(name)") }
        return value
    }

    private func table(_ value: LuaValue, key: String) throws -> [String: LuaValue] {
        guard case .table(let table) = value else {
            throw ConfigError.wrongType(key: key, expected: "table")
        }
        return table
    }

    private func array(_ value: LuaValue, key: String) throws -> [LuaValue] {
        guard case .array(let array) = value else {
            throw ConfigError.wrongType(key: key, expected: "array")
        }
        return array
    }

    private func string(_ value: LuaValue, key: String) throws -> String {
        guard case .string(let string) = value else {
            throw ConfigError.wrongType(key: key, expected: "string")
        }
        return string
    }

    private func nonEmptyString(_ value: LuaValue, key: String) throws -> String {
        let value = try string(value, key: key)
        guard !value.isEmpty else {
            throw ConfigError.invalidValue(key: key, reason: "value cannot be empty")
        }
        return value
    }

    private func regexPattern(_ value: LuaValue, key: String) throws -> String {
        let pattern = try nonEmptyString(value, key: key)
        do {
            _ = try Regex(pattern)
        } catch {
            throw ConfigError.invalidValue(key: key, reason: "invalid regex")
        }
        return pattern
    }

    private func bool(_ value: LuaValue, key: String) throws -> Bool {
        guard case .bool(let bool) = value else {
            throw ConfigError.wrongType(key: key, expected: "boolean")
        }
        return bool
    }

    private func nonNegativeNumber(_ value: LuaValue, key: String) throws -> Double {
        try boundedNumber(value, key: key, min: 0, max: nil)
    }

    private func boundedNumber(_ value: LuaValue, key: String, min: Double, max: Double?) throws -> Double {
        guard case .number(let number) = value else {
            throw ConfigError.wrongType(key: key, expected: "number")
        }
        guard number.isFinite else {
            throw ConfigError.invalidValue(key: key, reason: "number must be finite")
        }
        guard number >= min else {
            throw ConfigError.invalidValue(key: key, reason: "number must be >= \(min)")
        }
        if let max, number > max {
            throw ConfigError.invalidValue(key: key, reason: "number must be <= \(max)")
        }
        return number
    }

    private func nonNegativeInt(_ value: LuaValue, key: String) throws -> Int {
        let number = try nonNegativeNumber(value, key: key)
        guard number.rounded() == number else {
            throw ConfigError.invalidValue(key: key, reason: "number must be an integer")
        }
        return Int(number)
    }

    private func modifier(named name: String, key: String) throws -> ModifierSet {
        switch name {
        case "shift":
            return .shift
        case "command", "cmd":
            return .command
        case "option", "alt":
            return .option
        case "control", "ctrl":
            return .control
        default:
            throw ConfigError.invalidValue(key: key, reason: "unsupported modifier '\(name)'")
        }
    }

    private func isHexRGB(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 7, scalars.first == "#" else { return false }
        return scalars.dropFirst().allSatisfy { scalar in
            (48...57).contains(scalar.value) || (65...70).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }
}
