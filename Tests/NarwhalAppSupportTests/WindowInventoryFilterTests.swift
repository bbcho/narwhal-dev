import CoreGraphics
import Testing
@testable import NarwhalAppSupport

@Suite("Window inventory filter")
struct WindowInventoryFilterTests {
    @Test("Own process layer-zero windows are excluded")
    func ownProcessLayerZeroWindowsAreExcluded() {
        let filter = WindowInventoryFilter(currentProcessID: 42)

        #expect(!filter.accepts(
            layer: 0,
            ownerPID: 42,
            frame: CGRect(x: -1, y: 30, width: 1922, height: 2031)
        ))
    }

    @Test("Other process layer-zero windows with real frames are accepted")
    func otherProcessLayerZeroWindowsAreAccepted() {
        let filter = WindowInventoryFilter(currentProcessID: 42)

        #expect(filter.accepts(
            layer: 0,
            ownerPID: 77,
            frame: CGRect(x: 0, y: 30, width: 1920, height: 1015)
        ))
    }

    @Test("Non-normal layers and empty frames are excluded")
    func nonNormalLayersAndEmptyFramesAreExcluded() {
        let filter = WindowInventoryFilter(currentProcessID: 42)

        #expect(!filter.accepts(
            layer: 1,
            ownerPID: 77,
            frame: CGRect(x: 0, y: 30, width: 1920, height: 1015)
        ))
        #expect(!filter.accepts(
            layer: 0,
            ownerPID: 77,
            frame: CGRect(x: 0, y: 30, width: 0, height: 1015)
        ))
    }
}
