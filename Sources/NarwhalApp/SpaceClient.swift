import Darwin
import CoreGraphics
import Foundation
import NarwhalCore

enum SpaceClientError: Error, Equatable, CustomStringConvertible {
    case symbolUnavailable(String)
    case connectionUnavailable
    case activeSpaceUnavailable

    var description: String {
        switch self {
        case .symbolUnavailable(let symbol):
            return "private CoreGraphics symbol unavailable: \(symbol)"
        case .connectionUnavailable:
            return "CoreGraphics connection unavailable"
        case .activeSpaceUnavailable:
            return "CGSGetActiveSpace returned 0"
        }
    }
}

struct SpaceClient {
    private let symbols: SpaceSymbols

    init(symbols: SpaceSymbols = .live) {
        self.symbols = symbols
    }

    func activeSpaceID() -> Result<SpaceID, SpaceClientError> {
        guard let getActiveSpace = symbols.getActiveSpace else {
            return .failure(.symbolUnavailable("CGSGetActiveSpace"))
        }
        guard let connectionID = symbols.connectionID() else {
            return .failure(.connectionUnavailable)
        }

        let raw = getActiveSpace(connectionID)
        guard raw != 0 else {
            return .failure(.activeSpaceUnavailable)
        }
        return .success(SpaceID(raw: raw))
    }

    func spaceTopology(displays: [DisplayID: DisplayInfo], windows: [WindowMetadata]) -> SpaceTopology {
        guard let connectionID = symbols.connectionID() else {
            return SpaceTopology.replicated(activeSpace: tryActiveSpaceID(), displays: displays)
        }

        let activeTopology = symbols.copyManagedDisplaySpaces
            .flatMap { copyManagedDisplaySpaces in
                copyManagedDisplaySpaces(connectionID)?.takeRetainedValue()
            }
            .flatMap { ManagedDisplaySpacesParser.parse($0, displays: displays) }
            ?? SpaceTopology.replicated(activeSpace: tryActiveSpaceID(), displays: displays)

        var windowSpace = activeTopology.windowSpace
        if let copySpacesForWindows = symbols.copySpacesForWindows {
            windowSpace.merge(windowSpaces(
                for: windows,
                displays: displays,
                activeSpaceByDisplay: activeTopology.activeSpaceByDisplay,
                connectionID: connectionID,
                copySpacesForWindows: copySpacesForWindows
            )) { _, live in live }
        }

        return SpaceTopology(
            activeSpaceByDisplay: activeTopology.activeSpaceByDisplay,
            windowSpace: windowSpace,
            quality: activeTopology.quality
        )
    }

    private func tryActiveSpaceID() -> SpaceID? {
        guard case .success(let spaceID) = activeSpaceID() else { return nil }
        return spaceID
    }
}

typealias CGSConnectionID = Int32
typealias CGSGetActiveSpaceFunction = @convention(c) (CGSConnectionID) -> UInt64
typealias CGSConnectionIDFunction = @convention(c) () -> CGSConnectionID
typealias SLSCopyManagedDisplaySpacesFunction = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
typealias SLSCopySpacesForWindowsFunction = @convention(c) (CGSConnectionID, Int, CFArray) -> Unmanaged<CFArray>?

struct SpaceSymbols {
    static let live = SpaceSymbols(
        getActiveSpace: loadSymbol("CGSGetActiveSpace", as: CGSGetActiveSpaceFunction.self),
        copyManagedDisplaySpaces: loadSymbol("SLSCopyManagedDisplaySpaces", as: SLSCopyManagedDisplaySpacesFunction.self),
        copySpacesForWindows: loadSymbol("SLSCopySpacesForWindows", as: SLSCopySpacesForWindowsFunction.self)
            ?? loadSymbol("CGSCopySpacesForWindows", as: SLSCopySpacesForWindowsFunction.self),
        mainConnectionID: loadSymbol("CGSMainConnectionID", as: CGSConnectionIDFunction.self),
        defaultConnection: loadSymbol("_CGSDefaultConnection", as: CGSConnectionIDFunction.self)
    )

    let getActiveSpace: CGSGetActiveSpaceFunction?
    let copyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFunction?
    let copySpacesForWindows: SLSCopySpacesForWindowsFunction?
    let mainConnectionID: CGSConnectionIDFunction?
    let defaultConnection: CGSConnectionIDFunction?

    func connectionID() -> CGSConnectionID? {
        if let connectionID = mainConnectionID?(), connectionID != 0 {
            return connectionID
        }
        if let connectionID = defaultConnection?(), connectionID != 0 {
            return connectionID
        }
        return nil
    }
}

private let coreGraphicsHandle = dlopen(
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    RTLD_LAZY
)
private let skyLightHandle = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    RTLD_LAZY
)
private let dynamicLoaderDefault = UnsafeMutableRawPointer(bitPattern: -2)

private func loadSymbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let symbol = loadRawSymbol(name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

private func loadRawSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    if let dynamicLoaderDefault, let symbol = dlsym(dynamicLoaderDefault, name) {
        return symbol
    }
    if let skyLightHandle, let symbol = dlsym(skyLightHandle, name) {
        return symbol
    }
    guard let coreGraphicsHandle else { return nil }
    return dlsym(coreGraphicsHandle, name)
}

private func windowSpaces(
    for windows: [WindowMetadata],
    displays: [DisplayID: DisplayInfo],
    activeSpaceByDisplay: [DisplayID: SpaceID],
    connectionID: CGSConnectionID,
    copySpacesForWindows: SLSCopySpacesForWindowsFunction
) -> [WindowID: SpaceID] {
    windows.reduce(into: [:]) { result, metadata in
        let ids = [NSNumber(value: metadata.id.raw)]
        guard let rawSpaces = copySpacesForWindows(connectionID, 7, ids as CFArray)?.takeRetainedValue() else {
            return
        }
        let spaces = (rawSpaces as NSArray)
            .compactMap { ($0 as? NSNumber).map { SpaceID(raw: $0.uint64Value) } }
        guard !spaces.isEmpty else { return }
        if spaces.count == 1, let onlySpace = spaces.first {
            result[metadata.id] = onlySpace
            return
        }
        let displayID = displayContaining(frame: metadata.frame, displays: displays)
        if let displayID,
           let activeSpace = activeSpaceByDisplay[displayID],
           spaces.contains(activeSpace) {
            result[metadata.id] = activeSpace
        } else if let first = spaces.sorted(by: { $0.raw < $1.raw }).first {
            result[metadata.id] = first
        }
    }
}

private func displayContaining(frame: CGRect, displays: [DisplayID: DisplayInfo]) -> DisplayID? {
    if let byIntersection = displays.max(by: { lhs, rhs in
        lhs.value.visibleFrame.intersection(frame).area < rhs.value.visibleFrame.intersection(frame).area
    }), byIntersection.value.visibleFrame.intersection(frame).area > 0 {
        return byIntersection.key
    }

    let center = CGPoint(x: frame.midX, y: frame.midY)
    return displays.min(by: { lhs, rhs in
        lhs.value.visibleFrame.center.distanceSquared(to: center) < rhs.value.visibleFrame.center.distanceSquared(to: center)
    })?.key
}

private enum ManagedDisplaySpacesParser {
    static func parse(_ raw: CFArray, displays: [DisplayID: DisplayInfo]) -> SpaceTopology? {
        let displayRows = raw as NSArray
        let displaysByFingerprint = Dictionary(
            uniqueKeysWithValues: displays.compactMap { displayID, display -> (String, DisplayID)? in
                guard let fingerprint = display.fingerprint?.lowercased() else { return nil }
                return (fingerprint, displayID)
            }
        )
        let displaysBySlot = displays.values.sorted { lhs, rhs in
            if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
            return lhs.id.raw < rhs.id.raw
        }

        var activeSpaceByDisplay: [DisplayID: SpaceID] = [:]
        var windowSpace: [WindowID: SpaceID] = [:]

        for index in 0..<displayRows.count {
            guard let row = displayRows[index] as? NSDictionary else { continue }
            let displayID = displayIdentifier(in: row).flatMap { displaysByFingerprint[$0.lowercased()] }
                ?? displaysBySlot[safe: index]?.id
            guard let displayID else { continue }

            if let activeSpace = spaceID(from: dictionaryValue(in: row, keys: ["Current Space", "current_space"])) {
                activeSpaceByDisplay[displayID] = activeSpace
            }

            guard let spaces = arrayValue(in: row, keys: ["Spaces", "spaces"]) else { continue }
            for case let space as NSDictionary in spaces {
                guard let spaceID = spaceID(from: space) else { continue }
                for windowID in windowIDs(inSpaceDictionary: space) {
                    windowSpace[windowID] = spaceID
                }
            }
        }

        guard !activeSpaceByDisplay.isEmpty else { return nil }
        return SpaceTopology(
            activeSpaceByDisplay: activeSpaceByDisplay,
            windowSpace: windowSpace,
            quality: .managedDisplaySpaces
        )
    }

    private static func displayIdentifier(in row: NSDictionary) -> String? {
        stringValue(in: row, keys: [
            "Display Identifier",
            "display_identifier",
            "DisplayIdentifier",
            "Identifier"
        ])
    }

    private static func spaceID(from value: Any?) -> SpaceID? {
        if let dictionary = value as? NSDictionary {
            return spaceID(from: dictionary)
        }
        if let number = numericValue(value) {
            return SpaceID(raw: number)
        }
        return nil
    }

    private static func spaceID(from dictionary: NSDictionary) -> SpaceID? {
        numericValue(dictionary["id64"])
            .map(SpaceID.init(raw:))
            ?? numericValue(dictionary["ManagedSpaceID"]).map(SpaceID.init(raw:))
            ?? numericValue(dictionary["id"]).map(SpaceID.init(raw:))
            ?? numericValue(dictionary["ID"]).map(SpaceID.init(raw:))
    }

    private static func windowIDs(inSpaceDictionary dictionary: NSDictionary) -> [WindowID] {
        var result: [WindowID] = []
        for key in dictionary.allKeys {
            guard let keyString = key as? String,
                  keyString.lowercased().contains("window")
            else { continue }
            result.append(contentsOf: windowIDs(in: dictionary[key]))
        }
        return result
    }

    private static func windowIDs(in value: Any?) -> [WindowID] {
        if let number = numericValue(value) {
            return [WindowID(raw: CGWindowID(number))]
        }
        if let array = value as? NSArray {
            return array.flatMap { windowIDs(in: $0) }
        }
        if let dictionary = value as? NSDictionary {
            return dictionary.allValues.flatMap { windowIDs(in: $0) }
        }
        return []
    }

    private static func stringValue(in dictionary: NSDictionary, keys: [String]) -> String? {
        keys.compactMap { dictionary[$0] as? String }.first
    }

    private static func arrayValue(in dictionary: NSDictionary, keys: [String]) -> NSArray? {
        keys.compactMap { dictionary[$0] as? NSArray }.first
    }

    private static func dictionaryValue(in dictionary: NSDictionary, keys: [String]) -> Any? {
        keys.compactMap { dictionary[$0] }.first
    }

    private static func numericValue(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        return number.uint64Value
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
