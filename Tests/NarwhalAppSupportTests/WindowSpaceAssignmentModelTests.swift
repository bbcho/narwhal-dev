import CoreGraphics
import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Window Space assignment model")
struct WindowSpaceAssignmentModelTests {
    @Test("Selected window Space returns nil for empty candidates and exact Space for single candidate")
    func selectedWindowSpaceHandlesEmptyAndSingleCandidates() {
        let metadata = windowFixture(frame: CGRect(x: 10, y: 10, width: 100, height: 100))

        #expect(selectedWindowSpace(
            for: metadata,
            candidateSpaces: [],
            displays: displaysFixture(),
            activeSpaceByDisplay: [:]
        ) == nil)
        #expect(selectedWindowSpace(
            for: metadata,
            candidateSpaces: [SpaceID(raw: 7)],
            displays: displaysFixture(),
            activeSpaceByDisplay: [:]
        ) == SpaceID(raw: 7))
    }

    @Test("Selected window Space prefers active Space for containing display")
    func selectedWindowSpacePrefersActiveSpaceForContainingDisplay() {
        let leftDisplay = DisplayID(raw: 1)
        let rightDisplay = DisplayID(raw: 2)
        let metadata = windowFixture(frame: CGRect(x: 1200, y: 100, width: 300, height: 200))

        let selected = selectedWindowSpace(
            for: metadata,
            candidateSpaces: [SpaceID(raw: 3), SpaceID(raw: 9)],
            displays: displaysFixture(),
            activeSpaceByDisplay: [
                leftDisplay: SpaceID(raw: 3),
                rightDisplay: SpaceID(raw: 9)
            ]
        )

        #expect(selected == SpaceID(raw: 9))
    }

    @Test("Selected window Space falls back to lowest candidate when active Space is absent")
    func selectedWindowSpaceFallsBackToLowestCandidateWhenActiveSpaceIsAbsent() {
        let metadata = windowFixture(frame: CGRect(x: 1200, y: 100, width: 300, height: 200))

        let selected = selectedWindowSpace(
            for: metadata,
            candidateSpaces: [SpaceID(raw: 9), SpaceID(raw: 3)],
            displays: displaysFixture(),
            activeSpaceByDisplay: [:]
        )

        #expect(selected == SpaceID(raw: 3))
    }

    @Test("Display containing chooses largest intersection before nearest center fallback")
    func displayContainingChoosesLargestIntersectionBeforeNearestCenterFallback() {
        let displays = displaysFixture()

        let largestIntersection = displayContaining(
            frame: CGRect(x: 900, y: 100, width: 300, height: 200),
            displays: displays
        )
        let offscreenNearestRight = displayContaining(
            frame: CGRect(x: 1900, y: 100, width: 100, height: 100),
            displays: displays
        )

        #expect(largestIntersection == DisplayID(raw: 2))
        #expect(offscreenNearestRight == DisplayID(raw: 2))
    }

    private func displaysFixture() -> [DisplayID: DisplayInfo] {
        [
            DisplayID(raw: 1): DisplayInfo(
                id: DisplayID(raw: 1),
                slot: 0,
                fingerprint: "left",
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 760)
            ),
            DisplayID(raw: 2): DisplayInfo(
                id: DisplayID(raw: 2),
                slot: 1,
                fingerprint: "right",
                frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 760)
            )
        ]
    }

    private func windowFixture(frame: CGRect) -> WindowMetadata {
        WindowMetadata(
            id: WindowID(raw: 42),
            bundleID: BundleID(raw: "com.example"),
            title: "Window",
            role: "AXWindow",
            pid: ProcessID(42),
            frame: frame,
            isResizable: true,
            isMinimized: false
        )
    }
}
