import CoreGraphics
import Darwin

public struct WindowInventoryFilter: Sendable {
    public let currentProcessID: pid_t

    public init(currentProcessID: pid_t) {
        self.currentProcessID = currentProcessID
    }

    public func accepts(layer: Int, ownerPID: pid_t, frame: CGRect) -> Bool {
        layer == 0
            && ownerPID != currentProcessID
            && frame.width > 0
            && frame.height > 0
    }
}
