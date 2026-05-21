import CoreGraphics
import Foundation
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Managed display spaces parser")
struct ManagedDisplaySpacesParserTests {
    @Test("Topology builder maps immutable rows by fingerprint and slot")
    func topologyBuilderMapsRowsByFingerprintAndSlot() throws {
        let firstDisplay = DisplayID(raw: 10)
        let secondDisplay = DisplayID(raw: 20)
        let topology = try #require(managedDisplaySpacesTopology(
            rows: [
                ManagedDisplaySpacesDisplayRow(
                    fingerprint: "SECOND-FINGERPRINT",
                    activeSpace: SpaceID(raw: 8),
                    spaces: [
                        ManagedDisplaySpace(
                            id: SpaceID(raw: 8),
                            windowIDs: [WindowID(raw: 8001), WindowID(raw: 8002)]
                        )
                    ]
                ),
                ManagedDisplaySpacesDisplayRow(
                    fingerprint: nil,
                    activeSpace: SpaceID(raw: 7),
                    spaces: [
                        ManagedDisplaySpace(id: SpaceID(raw: 7), windowIDs: [WindowID(raw: 7001)])
                    ]
                )
            ],
            displays: [
                secondDisplay: display(secondDisplay, slot: 0, fingerprint: "second-fingerprint"),
                firstDisplay: display(firstDisplay, slot: 1, fingerprint: nil)
            ]
        ))

        #expect(topology.quality == .managedDisplaySpaces)
        #expect(topology.activeSpaceByDisplay == [
            secondDisplay: SpaceID(raw: 8),
            firstDisplay: SpaceID(raw: 7)
        ])
        #expect(topology.windowSpace == [
            WindowID(raw: 8001): SpaceID(raw: 8),
            WindowID(raw: 8002): SpaceID(raw: 8),
            WindowID(raw: 7001): SpaceID(raw: 7)
        ])
    }

    @Test("Topology builder uses latest row order for duplicate window ownership")
    func topologyBuilderUsesLatestRowOrderForDuplicateWindowOwnership() throws {
        let displayID = DisplayID(raw: 11)
        let windowID = WindowID(raw: 9001)
        let topology = try #require(managedDisplaySpacesTopology(
            rows: [
                ManagedDisplaySpacesDisplayRow(
                    fingerprint: nil,
                    activeSpace: SpaceID(raw: 1),
                    spaces: [
                        ManagedDisplaySpace(id: SpaceID(raw: 1), windowIDs: [windowID]),
                        ManagedDisplaySpace(id: SpaceID(raw: 2), windowIDs: [windowID])
                    ]
                )
            ],
            displays: [
                displayID: display(displayID, slot: 0, fingerprint: nil)
            ]
        ))

        #expect(topology.windowSpace == [windowID: SpaceID(raw: 2)])
    }

    @Test("Display row projection exposes all Spaces for live shell verifiers")
    func displayRowProjectionExposesAllSpacesForLiveShellVerifiers() throws {
        let displayID = DisplayID(raw: 12)
        let rows = [
            ManagedDisplaySpacesDisplayRow(
                fingerprint: "display-fingerprint",
                activeSpace: SpaceID(raw: 21),
                spaces: [
                    ManagedDisplaySpace(id: SpaceID(raw: 20), windowIDs: []),
                    ManagedDisplaySpace(id: SpaceID(raw: 21), windowIDs: [WindowID(raw: 2101)]),
                    ManagedDisplaySpace(id: SpaceID(raw: 22), windowIDs: [])
                ]
            )
        ]

        let projected = managedDisplaySpaceRowsByDisplay(
            rows: rows,
            displays: [
                displayID: display(displayID, slot: 0, fingerprint: "DISPLAY-FINGERPRINT")
            ]
        )

        #expect(projected[displayID]?.activeSpace == SpaceID(raw: 21))
        #expect(projected[displayID]?.spaces.map(\.id) == [
            SpaceID(raw: 20),
            SpaceID(raw: 21),
            SpaceID(raw: 22)
        ])
    }

    @Test("Topology builder rejects rows without any active Space")
    func topologyBuilderRejectsRowsWithoutAnyActiveSpace() {
        let topology = managedDisplaySpacesTopology(
            rows: [
                ManagedDisplaySpacesDisplayRow(
                    fingerprint: nil,
                    activeSpace: nil,
                    spaces: [
                        ManagedDisplaySpace(id: SpaceID(raw: 1), windowIDs: [WindowID(raw: 100)])
                    ]
                )
            ],
            displays: [
                DisplayID(raw: 1): display(DisplayID(raw: 1), slot: 0, fingerprint: nil)
            ]
        )

        #expect(topology == nil)
    }

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

    @Test("Parser preserves raw row position for slot fallback when rows are malformed")
    func parserPreservesRawRowPositionForSlotFallbackWhenRowsAreMalformed() throws {
        let firstDisplay = DisplayID(raw: 10)
        let secondDisplay = DisplayID(raw: 20)
        let raw = [
            "not a display row",
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
