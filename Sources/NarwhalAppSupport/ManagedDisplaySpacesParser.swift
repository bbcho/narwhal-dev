import CoreGraphics
import Foundation
import NarwhalCore

public enum ManagedDisplaySpacesParser {
    public static func parse(_ raw: CFArray, displays: [DisplayID: DisplayInfo]) -> SpaceTopology? {
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
