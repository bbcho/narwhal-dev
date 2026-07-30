import CoreGraphics
import Testing
@testable import NarwhalCore

@Suite("Snapped application frame gaps")
struct SnappedFrameGapTests {
    @Test("Frame writes follow seam dependencies instead of window IDs")
    func leadingWriteOrder() {
        let left = WindowID(raw: 30)
        let middle = WindowID(raw: 10)
        let right = WindowID(raw: 20)
        let planned = [
            left: CGRect(x: 0, y: 0, width: 500, height: 800),
            middle: CGRect(x: 508, y: 0, width: 500, height: 800),
            right: CGRect(x: 1_016, y: 0, width: 500, height: 800),
        ]

        #expect(leadingFrameWriteOrder(
            planned: planned,
            candidates: Set(planned.keys),
            innerGap: 8
        ) == [left, middle, right])
    }

    @Test("Terminal-sized horizontal tiles keep the configured interior gap")
    func horizontalTerminalFrames() throws {
        let planned = horizontalFrames(widths: [602, 602, 601, 602, 601], height: 781)
        let actual = planned.mapValues { frame in
            CGRect(x: frame.minX, y: frame.minY, width: 590, height: 777)
        }

        let reflowed = try reflowSnappedFrames(
            planned: planned,
            actual: actual,
            innerGap: 0
        ).get()

        #expect(innerGapViolations(planned: planned, actual: reflowed, innerGap: 0).isEmpty)
        #expect(reflowed[WindowID(raw: 1)]?.minX == 29)
        #expect(reflowed[WindowID(raw: 5)]?.maxX == 2_979)
        #expect(reflowed.values.allSatisfy { $0.size == CGSize(width: 590, height: 777) })
    }

    @Test("Terminal-sized vertical tiles keep the configured interior gap")
    func verticalTerminalFrames() throws {
        let planned = verticalFrames(heights: [196, 195, 195, 195, 195, 195, 195, 196], width: 3_008)
        let actual = planned.mapValues { frame in
            CGRect(x: frame.minX, y: frame.minY, width: 3_005, height: 189)
        }

        let reflowed = try reflowSnappedFrames(
            planned: planned,
            actual: actual,
            innerGap: 0
        ).get()

        #expect(innerGapViolations(planned: planned, actual: reflowed, innerGap: 0).isEmpty)
        #expect(reflowed[WindowID(raw: 1)]?.minY == 25)
        #expect(reflowed[WindowID(raw: 8)]?.maxY == 1_537)
    }

    @Test("A non-zero configured gap survives application undershoot")
    func configuredGap() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let planned = [
            first: CGRect(x: 4, y: 4, width: 492, height: 792),
            second: CGRect(x: 504, y: 4, width: 492, height: 792),
        ]
        let actual = [
            first: CGRect(x: 4, y: 4, width: 485, height: 790),
            second: CGRect(x: 504, y: 4, width: 485, height: 790),
        ]

        let reflowed = try reflowSnappedFrames(
            planned: planned,
            actual: actual,
            innerGap: 8
        ).get()

        #expect(reflowed[first]?.minX == 11)
        #expect(reflowed[second]?.minX == 504)
        #expect(innerGapViolations(planned: planned, actual: reflowed, innerGap: 8).isEmpty)
    }

    @Test("Gap validation does not inherit the looser frame settle tolerance")
    func strictGapTolerance() {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let firstFrame = CGRect(x: 0, y: 0, width: 500, height: 800)
        let planned = [
            first: firstFrame,
            second: CGRect(x: 500, y: 0, width: 500, height: 800),
        ]

        #expect(innerGapViolations(
            planned: planned,
            actual: [
                first: firstFrame,
                second: CGRect(x: 500.75, y: 0, width: 499.25, height: 800),
            ],
            innerGap: 0
        ).count == 1)
        #expect(innerGapViolations(
            planned: planned,
            actual: [
                first: firstFrame,
                second: CGRect(x: 500.25, y: 0, width: 499.75, height: 800),
            ],
            innerGap: 0
        ).isEmpty)
    }

    @Test("A branched seam aligns every adjacent window")
    func branchedSeam() throws {
        let left = WindowID(raw: 1)
        let topRight = WindowID(raw: 2)
        let bottomRight = WindowID(raw: 3)
        let planned = [
            left: CGRect(x: 0, y: 0, width: 500, height: 1_000),
            topRight: CGRect(x: 500, y: 0, width: 500, height: 500),
            bottomRight: CGRect(x: 500, y: 500, width: 500, height: 500),
        ]
        let actual = [
            left: CGRect(x: 0, y: 0, width: 480, height: 990),
            topRight: CGRect(x: 500, y: 0, width: 470, height: 490),
            bottomRight: CGRect(x: 500, y: 500, width: 460, height: 490),
        ]

        let reflowed = try reflowSnappedFrames(
            planned: planned,
            actual: actual,
            innerGap: 0
        ).get()

        #expect(reflowed[left]?.maxX == reflowed[topRight]?.minX)
        #expect(reflowed[left]?.maxX == reflowed[bottomRight]?.minX)
        #expect(innerGapViolations(planned: planned, actual: reflowed, innerGap: 0).isEmpty)
    }

    @Test("A manually resized window anchors its connected group")
    func manualAnchor() throws {
        let left = WindowID(raw: 1)
        let right = WindowID(raw: 2)
        let planned = [
            left: CGRect(x: 0, y: 0, width: 500, height: 800),
            right: CGRect(x: 500, y: 0, width: 500, height: 800),
        ]
        let actual = [
            left: CGRect(x: 0, y: 0, width: 490, height: 797),
            right: CGRect(x: 500, y: 0, width: 490, height: 797),
        ]

        let reflowed = try reflowSnappedFrames(
            planned: planned,
            actual: actual,
            innerGap: 0,
            anchoredWindowIDs: [right]
        ).get()

        #expect(reflowed[right] == actual[right])
        #expect(reflowed[left]?.minX == 10)
        #expect(reflowed[left]?.maxX == reflowed[right]?.minX)
    }

    @Test("Incompatible application widths are an explicit conflict")
    func inconsistentDiamond() {
        let left = WindowID(raw: 1)
        let topMiddle = WindowID(raw: 2)
        let bottomMiddle = WindowID(raw: 3)
        let right = WindowID(raw: 4)
        let planned = [
            left: CGRect(x: 0, y: 0, width: 300, height: 1_000),
            topMiddle: CGRect(x: 300, y: 0, width: 300, height: 500),
            bottomMiddle: CGRect(x: 300, y: 500, width: 300, height: 500),
            right: CGRect(x: 600, y: 0, width: 300, height: 1_000),
        ]
        let actual = [
            left: CGRect(x: 0, y: 0, width: 290, height: 990),
            topMiddle: CGRect(x: 300, y: 0, width: 280, height: 490),
            bottomMiddle: CGRect(x: 300, y: 500, width: 270, height: 490),
            right: CGRect(x: 600, y: 0, width: 290, height: 990),
        ]

        switch reflowSnappedFrames(planned: planned, actual: actual, innerGap: 0) {
        case .success:
            Issue.record("Expected incompatible seam equations to fail")
        case .failure(let conflict):
            #expect(conflict.axis == .horizontal)
            #expect(Set(conflict.windows) == Set(planned.keys))
        }
    }

    @Test("Four through eight tiles keep exact horizontal and vertical gaps")
    func fourThroughEightTiles() throws {
        for count in 4...8 {
            for innerGap in [CGFloat(0), 8] {
                let lengths = wholePointLengths(total: 1_562, count: count)
                let horizontalPlan = horizontalFrames(widths: lengths, height: 800, gap: innerGap)
                let horizontalActual = horizontalPlan.mapValues { frame in
                    CGRect(x: frame.minX, y: frame.minY, width: frame.width - 7, height: frame.height - 3)
                }
                let horizontal = try reflowSnappedFrames(
                    planned: horizontalPlan,
                    actual: horizontalActual,
                    innerGap: Double(innerGap)
                ).get()
                #expect(innerGapViolations(
                    planned: horizontalPlan,
                    actual: horizontal,
                    innerGap: Double(innerGap)
                ).isEmpty)

                let verticalPlan = verticalFrames(heights: lengths, width: 1_200, gap: innerGap)
                let verticalActual = verticalPlan.mapValues { frame in
                    CGRect(x: frame.minX, y: frame.minY, width: frame.width - 3, height: frame.height - 7)
                }
                let vertical = try reflowSnappedFrames(
                    planned: verticalPlan,
                    actual: verticalActual,
                    innerGap: Double(innerGap)
                ).get()
                #expect(innerGapViolations(
                    planned: verticalPlan,
                    actual: vertical,
                    innerGap: Double(innerGap)
                ).isEmpty)
            }
        }
    }

    private func horizontalFrames(
        widths: [CGFloat],
        height: CGFloat,
        gap: CGFloat = 0
    ) -> [WindowID: CGRect] {
        var x: CGFloat = 0
        return Dictionary(uniqueKeysWithValues: widths.enumerated().map { index, width in
            defer { x += width + gap }
            return (WindowID(raw: UInt32(index + 1)), CGRect(x: x, y: 0, width: width, height: height))
        })
    }

    private func verticalFrames(
        heights: [CGFloat],
        width: CGFloat,
        gap: CGFloat = 0
    ) -> [WindowID: CGRect] {
        var y: CGFloat = 0
        return Dictionary(uniqueKeysWithValues: heights.enumerated().map { index, height in
            defer { y += height + gap }
            return (WindowID(raw: UInt32(index + 1)), CGRect(x: 0, y: y, width: width, height: height))
        })
    }

    private func wholePointLengths(total: Int, count: Int) -> [CGFloat] {
        (0..<count).map { index in
            let start = Int((Double(total) * Double(index) / Double(count)).rounded())
            let end = Int((Double(total) * Double(index + 1) / Double(count)).rounded())
            return CGFloat(end - start)
        }
    }
}
