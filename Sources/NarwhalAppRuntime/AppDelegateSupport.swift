import CoreGraphics
import NarwhalCore

extension WindowConstraints {
    var appDebugDescription: String {
        [
            "minWidth=\(minWidth.map { String($0) } ?? "nil")",
            "minHeight=\(minHeight.map { String($0) } ?? "nil")",
            "maxWidth=\(maxWidth.map { String($0) } ?? "nil")",
            "maxHeight=\(maxHeight.map { String($0) } ?? "nil")",
            "widthAnchor=\(widthAnchor?.rawValue ?? "nil")",
            "heightAnchor=\(heightAnchor?.rawValue ?? "nil")"
        ].joined(separator: " ")
    }
}

struct CommandExecutionFailure: Error {
    let code: String
    let message: String
}

struct FocusedLayoutContext {
    let metadata: WindowMetadata
    let displays: [DisplayID: DisplayInfo]

    var id: WindowID {
        metadata.id
    }

    var frame: CGRect {
        metadata.frame
    }

    var logDescription: String {
        "id=\(metadata.id.description) pid=\(metadata.pid) bundle=\(metadata.bundleID.raw) title=\"\(metadata.title)\" role=\(metadata.role) frame=\(metadata.frame.debugDescription)"
    }
}

struct DragZonePreview {
    let frame: CGRect
    let title: String
    let valid: Bool
}

enum AppDelegateGeometry {
    static func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
        point.x >= frame.minX
            && point.x < frame.maxX
            && point.y >= frame.minY
            && point.y < frame.maxY
    }

    static func contains(_ point: CGPoint, in rect: ProportionalRect) -> Bool {
        point.x >= CGFloat(rect.x)
            && point.x < CGFloat(rect.x + rect.w)
            && point.y >= CGFloat(rect.y)
            && point.y < CGFloat(rect.y + rect.h)
    }

    static func absoluteFrame(for rect: ProportionalRect, in displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + CGFloat(rect.x) * displayFrame.width,
            y: displayFrame.minY + CGFloat(rect.y) * displayFrame.height,
            width: CGFloat(rect.w) * displayFrame.width,
            height: CGFloat(rect.h) * displayFrame.height
        )
    }

    static func badgeFrame(around location: CGPoint) -> CGRect {
        CGRect(x: location.x - 90, y: location.y - 22, width: 180, height: 44)
    }
}

enum AppDelegateText {
    static func dropActionDescription(_ action: ZoneAction) -> String {
        switch action {
        case .insertAsHalf(let direction):
            return "\(edgeName(direction)) lane"
        case .insertAsQuarter(let corner):
            return "\(cornerName(corner)) quarter"
        case .insertAsCenter:
            return "center lane"
        case .insertAtSubtree(let path):
            return "subtree \(path)"
        }
    }

    static func describe(_ action: HotkeyAction) -> String {
        switch action {
        case .command(let template):
            return describe(template)
        case .openFinderWindow:
            return "open Finder window"
        case .reloadConfig:
            return "reload config"
        case .showCommands:
            return "show commands"
        }
    }

    static func describe(_ template: CommandTemplate) -> String {
        switch template {
        case .push(let direction):
            return "push \(direction.rawValue)"
        case .center:
            return "center"
        case .eject:
            return "eject"
        case .swap(let direction):
            return "swap \(direction.rawValue)"
        case .resizeSplit(let direction, let delta):
            return "resize \(direction.rawValue) \(delta)"
        case .focusDirection(let direction):
            return "focus \(direction.rawValue)"
        case .focusCycle(let direction):
            return "focus cycle \(direction.rawValue)"
        case .focusPrevious:
            return "focus previous"
        case .toggleFloat:
            return "toggleFloat"
        case .balance:
            return "balance"
        case .shuffle:
            return "shuffle"
        case .cascade:
            return "cascade"
        case .maximizeReset:
            return "max reset"
        case .undoLayout:
            return "undo layout"
        case .moveToNextDisplay:
            return "move display"
        case .togglePause:
            return "toggle pause"
        case .resetLayout:
            return "resetLayout"
        }
    }

    static func describe(_ quality: AXSnapshotQuality) -> String {
        switch quality {
        case .complete:
            return "complete"
        case .partial(let errors):
            return "partial(\(errors.count) errors)"
        case .permissionDenied(let message):
            return "permissionDenied(\(message))"
        }
    }

    private static func edgeName(_ direction: Direction) -> String {
        switch direction {
        case .left:
            return "left"
        case .right:
            return "right"
        case .up:
            return "top"
        case .down:
            return "bottom"
        }
    }

    private static func cornerName(_ corner: Corner) -> String {
        switch corner {
        case .topLeft:
            return "top-left"
        case .topRight:
            return "top-right"
        case .bottomLeft:
            return "bottom-left"
        case .bottomRight:
            return "bottom-right"
        }
    }
}
