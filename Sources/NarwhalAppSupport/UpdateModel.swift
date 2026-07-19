import Foundation

public enum SemanticVersionError: Error, Equatable, Sendable {
    case invalid(String)
}

public struct SemanticVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let major: UInt
    public let minor: UInt
    public let patch: UInt

    public init(_ rawValue: String) throws {
        let normalized = rawValue.hasPrefix("v") ? String(rawValue.dropFirst()) : rawValue
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Self.parseComponent(components[0]),
              let minor = Self.parseComponent(components[1]),
              let patch = Self.parseComponent(components[2])
        else {
            throw SemanticVersionError.invalid(rawValue)
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    private static func parseComponent(_ component: Substring) -> UInt? {
        guard !component.isEmpty,
              component.allSatisfy(\.isNumber),
              component == "0" || component.first != "0"
        else { return nil }
        return UInt(component)
    }
}

public enum UpdateAvailability: Equatable, Sendable {
    case current
    case newer(version: SemanticVersion, pageURL: URL)
}

public func updateAvailability(
    current: SemanticVersion,
    latest: SemanticVersion,
    pageURL: URL
) -> UpdateAvailability {
    latest > current ? .newer(version: latest, pageURL: pageURL) : .current
}

public enum UpdateMenuStatus: Equatable, Sendable {
    case idle
    case checking
    case current
    case available(version: SemanticVersion, pageURL: URL)
    case failed

    public var title: String {
        switch self {
        case .idle:
            return "Check for Updates…"
        case .checking:
            return "Checking for Updates…"
        case .current:
            return "Up to Date — Check Again"
        case .available(let version, _):
            return "Get Narwhal \(version.description)…"
        case .failed:
            return "Update Check Failed — Retry"
        }
    }

    public var isEnabled: Bool {
        self != .checking
    }
}
