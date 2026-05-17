import CoreGraphics

public struct WindowID: Hashable, Codable, CustomStringConvertible, Sendable {
    public let raw: CGWindowID

    public init(raw: CGWindowID) {
        self.raw = raw
    }

    public var description: String { "w\(raw)" }
}

public struct DisplayID: Hashable, Codable, Sendable {
    public let raw: CGDirectDisplayID

    public init(raw: CGDirectDisplayID) {
        self.raw = raw
    }
}

public struct SpaceID: Hashable, Codable, Sendable {
    public let raw: UInt64

    public init(raw: UInt64) {
        self.raw = raw
    }
}

public struct BundleID: Hashable, Codable, Sendable {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }
}

public typealias WinMgrProcessID = Int32
public typealias ProcessID = WinMgrProcessID

public struct CommandID: Hashable, Codable, Sendable {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }
}
