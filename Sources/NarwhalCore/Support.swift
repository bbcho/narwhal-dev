import CoreGraphics

public struct Insets: Equatable, Codable, Sendable {
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

public struct Gaps: Equatable, Codable, Sendable {
    public static let maximumLength = 512.0

    public let inner: Double
    public let outer: Insets

    public init(inner: Double, outer: Insets) {
        self.inner = inner
        self.outer = outer
    }
}

public struct ModifierSet: OptionSet, Equatable, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = ModifierSet(rawValue: 1 << 0)
    public static let command = ModifierSet(rawValue: 1 << 1)
    public static let option = ModifierSet(rawValue: 1 << 2)
    public static let control = ModifierSet(rawValue: 1 << 3)
}

public struct KeySpec: Equatable, Codable, Sendable {
    public let key: String
    public let modifiers: ModifierSet

    public init(key: String, modifiers: ModifierSet) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct BorderConfig: Equatable, Codable, Sendable {
    public static let maximumWidth = 32.0

    public let width: Double
    public let colorHex: String

    public init(width: Double, colorHex: String) {
        self.width = width
        self.colorHex = colorHex
    }

    public static let `default` = BorderConfig(width: 2, colorHex: "#4DA3FF")
}

public struct HUDConfig: Equatable, Codable, Sendable {
    public static let maximumDurationMillis = 60_000

    public let enabled: Bool
    public let durationMillis: Int

    public init(enabled: Bool, durationMillis: Int) {
        self.enabled = enabled
        self.durationMillis = durationMillis
    }

    public static func clampedDurationMillis(_ durationMillis: Int) -> Int {
        min(max(0, durationMillis), maximumDurationMillis)
    }

    public static let `default` = HUDConfig(enabled: true, durationMillis: 700)
}

public enum LuaValue: Equatable, Sendable {
    case nilValue
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LuaValue])
    case table([String: LuaValue])
}

public struct LuaConfigData: Equatable, Sendable {
    public let root: [String: LuaValue]

    public init(root: [String: LuaValue]) {
        self.root = root
    }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingKey(String)
    case wrongType(key: String, expected: String)
    case invalidValue(key: String, reason: String)

    public var description: String {
        switch self {
        case .missingKey(let key):
            return "Missing config key '\(key)'"
        case .wrongType(let key, let expected):
            return "Config key '\(key)' must be \(expected)"
        case .invalidValue(let key, let reason):
            return "Config key '\(key)' is invalid: \(reason)"
        }
    }
}

public enum InvariantError: Error, Equatable, CustomStringConvertible, Sendable {
    case splitNeedsAtLeastTwoCells
    case cellWeightMustBePositive
    case nonFiniteNumber(String)

    public var description: String {
        switch self {
        case .splitNeedsAtLeastTwoCells:
            return "splitNeedsAtLeastTwoCells"
        case .cellWeightMustBePositive:
            return "cellWeightMustBePositive"
        case .nonFiniteNumber(let field):
            return "nonFiniteNumber(\(field))"
        }
    }
}

public enum RestoreError: Error, Equatable, Sendable {
    case invalidStoredWorld(String)
}
