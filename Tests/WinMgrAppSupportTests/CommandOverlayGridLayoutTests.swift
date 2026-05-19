import CoreGraphics
import Testing
@testable import WinMgrAppSupport

@Suite("Command overlay grid layout")
struct CommandOverlayGridLayoutTests {
    @Test("Two command groups occupy opposite sides with a center separator")
    func twoCommandGroupsUseOppositeSides() {
        let bounds = CGRect(x: 0, y: 0, width: 941, height: 500)
        let frames = CommandOverlayGridLayout.columnFrames(
            in: bounds,
            columnCount: 2,
            centerGutter: 40,
            separatorWidth: 1
        )

        #expect(frames.columns.count == 2)
        #expect(frames.columns[0].minX == 0)
        #expect(frames.columns[0].maxX < bounds.midX)
        #expect(frames.separator?.minX == 470)
        #expect(frames.separator?.width == 1)
        #expect(frames.columns[1].minX > bounds.midX)
        #expect(frames.columns[1].maxX == bounds.maxX)
    }

    @Test("Single command group uses the full available width")
    func singleCommandGroupUsesFullWidth() {
        let bounds = CGRect(x: 12, y: 0, width: 430, height: 500)
        let frames = CommandOverlayGridLayout.columnFrames(
            in: bounds,
            columnCount: 1,
            centerGutter: 40,
            separatorWidth: 1
        )

        #expect(frames.columns == [bounds])
        #expect(frames.separator == nil)
    }

    @Test("Two command groups preserve the full right edge when the available width is odd")
    func twoCommandGroupsUseFullWidthWithOddAvailableWidth() {
        let bounds = CGRect(x: 0, y: 0, width: 941, height: 500)
        let frames = CommandOverlayGridLayout.columnFrames(
            in: bounds,
            columnCount: 2,
            centerGutter: 56,
            separatorWidth: 2
        )

        #expect(frames.columns.count == 2)
        #expect(frames.columns[0].minX == bounds.minX)
        #expect(frames.separator?.minX == 469)
        #expect(frames.separator?.width == 2)
        #expect(frames.columns[1].minX == 527)
        #expect(frames.columns[1].maxX == bounds.maxX)
        #expect(frames.columns[1].width == frames.columns[0].width + 1)
    }
}
