import CoreGraphics
import Foundation
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Managed display spaces parser")
struct ManagedDisplaySpacesParserTests {
    @Test("Parser maps active Spaces and nested window IDs by display fingerprint")
    func parserMapsActiveSpacesAndNestedWindowIDsByDisplayFingerprint() throws {
        let mainDisplay = DisplayID(raw: 3)
        let raw = [[
            "Display Identifier": "MAIN-FINGERPRINT",
            "Current Space": ["id64": NSNumber(value: 4)],
            "Spaces": [
                [
                    "id64": NSNumber(value: 4),
                    "Windows": [
                        NSNumber(value: 1001),
                        ["Nested Windows": [NSNumber(value: 1002)]]
                    ]
                ],
                [
                    "ManagedSpaceID": NSNumber(value: 5),
                    "Window List": [NSNumber(value: 1003)]
                ]
            ]
        ]] as NSArray as CFArray

        let topology = try #require(ManagedDisplaySpacesParser.parse(
            raw,
            displays: [
                mainDisplay: display(mainDisplay, slot: 0, fingerprint: "main-fingerprint")
            ]
        ))

        #expect(topology.quality == .managedDisplaySpaces)
        #expect(topology.activeSpaceByDisplay == [mainDisplay: SpaceID(raw: 4)])
        #expect(topology.windowSpace == [
            WindowID(raw: CGWindowID(1001)): SpaceID(raw: 4),
            WindowID(raw: CGWindowID(1002)): SpaceID(raw: 4),
            WindowID(raw: CGWindowID(1003)): SpaceID(raw: 5)
        ])
    }

    @Test("Parser falls back to display slot when fingerprint is unavailable")
    func parserFallsBackToDisplaySlotWhenFingerprintIsUnavailable() throws {
        let firstDisplay = DisplayID(raw: 10)
        let secondDisplay = DisplayID(raw: 20)
        let raw = [
            [
                "Current Space": NSNumber(value: 7),
                "spaces": [["id": NSNumber(value: 7)]]
            ],
            [
                "current_space": ["ID": NSNumber(value: 8)],
                "spaces": [["ID": NSNumber(value: 8)]]
            ]
        ] as NSArray as CFArray

        let topology = try #require(ManagedDisplaySpacesParser.parse(
            raw,
            displays: [
                secondDisplay: display(secondDisplay, slot: 1, fingerprint: nil),
                firstDisplay: display(firstDisplay, slot: 0, fingerprint: nil)
            ]
        ))

        #expect(topology.activeSpaceByDisplay == [
            firstDisplay: SpaceID(raw: 7),
            secondDisplay: SpaceID(raw: 8)
        ])
    }

    @Test("Parser rejects rows that cannot establish an active Space")
    func parserRejectsRowsThatCannotEstablishAnActiveSpace() {
        let raw = [[
            "Display Identifier": "main",
            "Spaces": [["id64": NSNumber(value: 4)]]
        ]] as NSArray as CFArray

        let topology = ManagedDisplaySpacesParser.parse(
            raw,
            displays: [
                DisplayID(raw: 1): display(DisplayID(raw: 1), slot: 0, fingerprint: "main")
            ]
        )

        #expect(topology == nil)
    }

    private func display(_ id: DisplayID, slot: Int, fingerprint: String?) -> DisplayInfo {
        DisplayInfo(
            id: id,
            slot: slot,
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 760)
        )
    }
}
