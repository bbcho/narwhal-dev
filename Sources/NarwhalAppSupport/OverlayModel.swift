import NarwhalCore

public struct OverlayModel: Equatable, Sendable {
    public let focusBorder: FocusBorderTarget?
    public let tiledBordersByWindowID: [WindowID: FocusBorderTarget]

    public init(
        focusBorder: FocusBorderTarget? = nil,
        tiledBordersByWindowID: [WindowID: FocusBorderTarget] = [:]
    ) {
        self.focusBorder = focusBorder
        self.tiledBordersByWindowID = tiledBordersByWindowID
    }

    public init(focusBorder: FocusBorderTarget? = nil, tiledBorders: [FocusBorderTarget]) {
        self.init(
            focusBorder: focusBorder,
            tiledBordersByWindowID: Dictionary(
                tiledBorders.map { ($0.windowID, $0) },
                uniquingKeysWith: { _, last in last }
            )
        )
    }

    public static let empty = OverlayModel()

    public var tiledBorders: [FocusBorderTarget] {
        tiledBordersByWindowID.values.sorted { $0.windowID.raw < $1.windowID.raw }
    }

    public func showingFocusBorder(_ target: FocusBorderTarget) -> OverlayModel {
        OverlayModel(focusBorder: target, tiledBordersByWindowID: tiledBordersByWindowID)
    }

    public func hidingFocusBorder() -> OverlayModel {
        OverlayModel(focusBorder: nil, tiledBordersByWindowID: tiledBordersByWindowID)
    }

    public func settingTiledBorders(_ targets: [FocusBorderTarget]) -> OverlayModel {
        OverlayModel(focusBorder: focusBorder, tiledBorders: targets)
    }

    public func removingWindow(_ windowID: WindowID) -> OverlayModel {
        return OverlayModel(
            focusBorder: focusBorder?.windowID == windowID ? nil : focusBorder,
            tiledBordersByWindowID: tiledBordersByWindowID.filter { $0.key != windowID }
        )
    }
}
