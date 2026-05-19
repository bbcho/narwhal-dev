import CoreGraphics

public struct CommandOverlayGridFrames: Equatable, Sendable {
    public let columns: [CGRect]
    public let separator: CGRect?

    public init(columns: [CGRect], separator: CGRect?) {
        self.columns = columns
        self.separator = separator
    }
}

public enum CommandOverlayGridLayout {
    public static func columnFrames(
        in bounds: CGRect,
        columnCount: Int,
        centerGutter: CGFloat,
        separatorWidth: CGFloat
    ) -> CommandOverlayGridFrames {
        guard columnCount > 0 else {
            return CommandOverlayGridFrames(columns: [], separator: nil)
        }
        guard columnCount > 1 else {
            return CommandOverlayGridFrames(columns: [bounds], separator: nil)
        }

        let availableWidth = max(0, bounds.width - centerGutter * 2 - separatorWidth)
        let firstColumnWidth = floor(availableWidth / 2)
        let secondColumnWidth = availableWidth - firstColumnWidth
        let usedWidth = firstColumnWidth + secondColumnWidth + centerGutter * 2 + separatorWidth
        let startX = bounds.minX + max(0, floor((bounds.width - usedWidth) / 2))
        let first = CGRect(x: startX, y: bounds.minY, width: firstColumnWidth, height: bounds.height)
        let separator = CGRect(
            x: first.maxX + centerGutter,
            y: bounds.minY,
            width: separatorWidth,
            height: bounds.height
        )
        let second = CGRect(
            x: separator.maxX + centerGutter,
            y: bounds.minY,
            width: secondColumnWidth,
            height: bounds.height
        )
        return CommandOverlayGridFrames(columns: [first, second], separator: separator)
    }
}
