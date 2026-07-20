import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Shared geometry helpers")
struct GeometryTests {
    @Test("Weighted split frames quantize shared edges and give the final cell the remaining extent")
    func weightedSplitFramesGiveFinalCellRemainingExtent() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 50)

        let frames = splitFrames(frame, axis: .horizontal, weights: [1, 2, 3])

        let expected = [
            CGRect(x: 10, y: 20, width: 17, height: 50),
            CGRect(x: 27, y: 20, width: 33, height: 50),
            CGRect(x: 60, y: 20, width: 50, height: 50)
        ]
        #expect(zip(frames, expected).allSatisfy { actual, expected in
            actual.narwhalApproximatelyEquals(expected, tolerance: 0.000_001)
        })
    }

    @Test("Thirds use representable shared boundaries without losing outer extent")
    func thirdsUseRepresentableSharedBoundaries() {
        let frame = CGRect(x: 0, y: 30, width: 3_008, height: 1_562)

        let horizontal = splitFrames(frame, axis: .horizontal, weights: [1, 1, 1])
        #expect(horizontal == [
            CGRect(x: 0, y: 30, width: 1_003, height: 1_562),
            CGRect(x: 1_003, y: 30, width: 1_002.5, height: 1_562),
            CGRect(x: 2_005.5, y: 30, width: 1_002.5, height: 1_562)
        ])

        let nested = splitFrames(horizontal[0], axis: .horizontal, weights: [1, 1])
        #expect(nested == [
            CGRect(x: 0, y: 30, width: 501.5, height: 1_562),
            CGRect(x: 501.5, y: 30, width: 501.5, height: 1_562)
        ])
    }

    @Test("Display attribution prefers intersection then nearest center")
    func displayAttributionPrefersIntersectionThenNearestCenter() {
        let left = DisplayID(raw: 1)
        let right = DisplayID(raw: 2)
        let displays: [DisplayID: DisplayInfo] = [
            left: DisplayInfo(
                id: left,
                slot: 0,
                fingerprint: nil,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
            ),
            right: DisplayInfo(
                id: right,
                slot: 1,
                fingerprint: nil,
                frame: CGRect(x: 100, y: 0, width: 100, height: 100),
                visibleFrame: CGRect(x: 100, y: 0, width: 100, height: 100)
            )
        ]

        #expect(displayContainingFrame(CGRect(x: 80, y: 0, width: 90, height: 50), displays: displays) == right)
        #expect(displayContainingFrame(CGRect(x: 220, y: 0, width: 10, height: 10), displays: displays) == right)
    }

    @Test("Approximate frame comparison uses the shared tolerance contract")
    func approximateFrameComparisonUsesSharedTolerance() {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let near = CGRect(x: 13, y: 16, width: 304, height: 197)
        let far = CGRect(x: 15, y: 20, width: 300, height: 200)

        #expect(frame.narwhalApproximatelyEquals(near, tolerance: GeometryTolerances.frameWriteSettle))
        #expect(!frame.narwhalApproximatelyEquals(far, tolerance: GeometryTolerances.frameWriteSettle))
        #expect(frame.narwhalArea == 60_000)
        #expect(frame.narwhalIsFinitePositive)
        #expect(!CGRect.null.narwhalIsFinitePositive)
    }
}
