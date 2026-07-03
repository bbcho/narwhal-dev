import CoreGraphics

public struct WindowResizeEligibilityTraits: Equatable, Sendable {
    public let role: String
    public let subrole: String
    public let axSizeAttributeSettable: Bool
    public let isMinimized: Bool
    public let isFullscreen: Bool
    public let frame: CGRect

    public init(
        role: String,
        subrole: String,
        axSizeAttributeSettable: Bool,
        isMinimized: Bool,
        isFullscreen: Bool,
        frame: CGRect
    ) {
        self.role = role
        self.subrole = subrole
        self.axSizeAttributeSettable = axSizeAttributeSettable
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.frame = frame
    }
}

public func windowResizeEligibility(_ traits: WindowResizeEligibilityTraits) -> Bool {
    guard !traits.isMinimized,
          !traits.isFullscreen,
          traits.frame.width > 0,
          traits.frame.height > 0,
          traits.frame.origin.x.isFinite,
          traits.frame.origin.y.isFinite,
          traits.frame.width.isFinite,
          traits.frame.height.isFinite
    else {
        return false
    }

    let role = traits.role.lowercased()
    let subrole = traits.subrole.lowercased()
    let descriptor = "\(role) \(subrole)"
    guard role == "axwindow" else { return false }
    guard !descriptor.contains("sheet"),
          !descriptor.contains("dialog"),
          !descriptor.contains("alert"),
          !descriptor.contains("floating"),
          !descriptor.contains("popover"),
          !descriptor.contains("drawer"),
          !descriptor.contains("utility")
    else {
        return false
    }

    if traits.axSizeAttributeSettable {
        return true
    }

    return subrole.isEmpty || subrole == "axstandardwindow"
}
