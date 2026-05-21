import CoreGraphics
import Foundation
import NarwhalCore

public struct ManagedDisplaySpace: Equatable, Sendable {
    public let id: SpaceID
    public let windowIDs: [WindowID]

    public init(id: SpaceID, windowIDs: [WindowID]) {
        self.id = id
        self.windowIDs = windowIDs
    }
}

public struct ManagedDisplaySpacesDisplayRow: Equatable, Sendable {
    public let fingerprint: String?
    public let activeSpace: SpaceID?
    public let spaces: [ManagedDisplaySpace]

    public init(fingerprint: String?, activeSpace: SpaceID?, spaces: [ManagedDisplaySpace]) {
        self.fingerprint = fingerprint
        self.activeSpace = activeSpace
        self.spaces = spaces
    }
}

public func managedDisplaySpacesTopology(
    rows: [ManagedDisplaySpacesDisplayRow],
    displays: [DisplayID: DisplayInfo]
) -> SpaceTopology? {
    let displayRows = managedDisplaySpaceRowsByDisplay(rows: rows, displays: displays)
    let activeSpaceByDisplay = Dictionary(
        displayRows.compactMap { displayID, row in
            row.activeSpace.map { (displayID, $0) }
        },
        uniquingKeysWith: { _, latest in latest }
    )
    guard !activeSpaceByDisplay.isEmpty else { return nil }

    let windowSpace = Dictionary(
        displayRows.flatMap { _, row in
            row.spaces.flatMap { space in
                space.windowIDs.map { windowID in (windowID, space.id) }
            }
        },
        uniquingKeysWith: { _, latest in latest }
    )
    return SpaceTopology(
        activeSpaceByDisplay: activeSpaceByDisplay,
        windowSpace: windowSpace,
        quality: .managedDisplaySpaces
    )
}

public func managedDisplaySpaceRowsByDisplay(
    rows: [ManagedDisplaySpacesDisplayRow],
    displays: [DisplayID: DisplayInfo]
) -> [DisplayID: ManagedDisplaySpacesDisplayRow] {
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
    let displayRows: [(DisplayID, ManagedDisplaySpacesDisplayRow)] = rows.enumerated().compactMap { index, row in
        let displayID = row.fingerprint.flatMap { displaysByFingerprint[$0.lowercased()] }
            ?? displaysBySlot[safe: index]?.id
        guard let displayID else { return nil }
        return (displayID, row)
    }

    return Dictionary(
        displayRows,
        uniquingKeysWith: { _, latest in latest }
    )
}

public enum ManagedDisplaySpacesParser {
    public static func parseRows(_ raw: CFArray) -> [ManagedDisplaySpacesDisplayRow] {
        let displayRows = raw as NSArray
        return (0..<displayRows.count).map { index -> ManagedDisplaySpacesDisplayRow in
            guard let row = displayRows[index] as? NSDictionary else {
                return ManagedDisplaySpacesDisplayRow(fingerprint: nil, activeSpace: nil, spaces: [])
            }
            return displayRow(from: row)
        }
    }

    public static func parse(_ raw: CFArray, displays: [DisplayID: DisplayInfo]) -> SpaceTopology? {
        managedDisplaySpacesTopology(rows: parseRows(raw), displays: displays)
    }

    private static func displayRow(from row: NSDictionary) -> ManagedDisplaySpacesDisplayRow {
        ManagedDisplaySpacesDisplayRow(
            fingerprint: displayIdentifier(in: row),
            activeSpace: spaceID(from: dictionaryValue(in: row, keys: ["Current Space", "current_space"])),
            spaces: managedSpaces(in: row)
        )
    }

    private static func managedSpaces(in row: NSDictionary) -> [ManagedDisplaySpace] {
        guard let spaces = arrayValue(in: row, keys: ["Spaces", "spaces"]) else { return [] }
        return spaces.compactMap { rawSpace -> ManagedDisplaySpace? in
            guard let space = rawSpace as? NSDictionary,
                  let spaceID = spaceID(from: space)
            else { return nil }
            return ManagedDisplaySpace(
                id: spaceID,
                windowIDs: windowIDs(inSpaceDictionary: space)
            )
        }
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
        dictionary.allKeys.flatMap { key -> [WindowID] in
            guard let keyString = key as? String,
                  keyString.lowercased().contains("window")
            else { return [] }
            return windowIDs(in: dictionary[key])
        }
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
