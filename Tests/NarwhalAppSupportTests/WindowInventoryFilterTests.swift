import CoreGraphics
import NarwhalCore
import Testing
@testable import NarwhalAppSupport

@Suite("Window inventory filter")
struct WindowInventoryFilterTests {
    @Test("Valid records survive alongside malformed relevant windows")
    func validRecordsSurviveAlongsideMalformedRelevantWindows() throws {
        let filter = WindowInventoryFilter(currentProcessID: 42)
        let validBounds = CGRect(x: 10, y: 20, width: 800, height: 600).dictionaryRepresentation
        let batch = filter.read([
            [
                kCGWindowLayer as String: 0,
                kCGWindowOwnerPID as String: pid_t(77),
                kCGWindowNumber as String: CGWindowID(9),
                kCGWindowName as String: "Editor",
                kCGWindowBounds as String: validBounds
            ],
            [
                kCGWindowLayer as String: 0,
                kCGWindowOwnerPID as String: pid_t(88),
                kCGWindowNumber as String: CGWindowID(10)
            ]
        ])

        #expect(batch.records == [WindowInventoryRecord(
            id: WindowID(raw: 9),
            ownerPID: 77,
            title: "Editor",
            frame: CGRect(x: 10, y: 20, width: 800, height: 600)
        )])
        #expect(batch.errors == [AXWindowReadError(
            windowID: WindowID(raw: 10),
            pid: 88,
            message: "missing or invalid window bounds"
        )])
    }

    @Test("Expected excluded windows do not degrade inventory quality")
    func expectedExcludedWindowsDoNotDegradeInventoryQuality() {
        let filter = WindowInventoryFilter(currentProcessID: 42)
        let batch = filter.read([
            [kCGWindowLayer as String: 7],
            [
                kCGWindowLayer as String: 0,
                kCGWindowOwnerPID as String: pid_t(42)
            ],
            [
                kCGWindowLayer as String: 0,
                kCGWindowOwnerPID as String: pid_t(77),
                kCGWindowNumber as String: CGWindowID(11),
                kCGWindowBounds as String: CGRect.zero.dictionaryRepresentation
            ]
        ])

        #expect(batch.records.isEmpty)
        #expect(batch.errors.isEmpty)
    }

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
