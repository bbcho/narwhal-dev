import CoreGraphics
import NarwhalCore
import Testing

@Suite("Space-scoped layout operations")
struct SpaceScopedLayoutTests {
    @Test("Resetting one Space preserves another display's active Space")
    func resetPreservesOtherSpace() {
        let fixture = world()

        let reset = resetSpaceTilingState(fixture.firstSpace, in: fixture.world)

        #expect(reset.spaces[fixture.firstSpace]?.displays[fixture.firstDisplay]?.tree == .void)
        #expect(reset.spaces[fixture.secondSpace]?.displays[fixture.secondDisplay]?.tree == .leaf(fixture.secondWindow))
        #expect(reset.windowSpace[fixture.secondWindow] == fixture.secondSpace)
        #expect(reset.windowConstraints[fixture.secondWindow] == WindowConstraints(minWidth: 500))
    }

    @Test("Space layout contains only the selected Space's windows")
    func spaceLayoutContainsOnlySelectedSpace() throws {
        let fixture = world()

        let first = try spaceLayout(for: fixture.firstSpace, in: fixture.world).get()
        let second = try spaceLayout(for: fixture.secondSpace, in: fixture.world).get()

        #expect(Set(first.tiled.keys) == [fixture.firstWindow])
        #expect(Set(second.tiled.keys) == [fixture.secondWindow])
    }

    private func world() -> (
        world: World,
        firstSpace: SpaceID,
        secondSpace: SpaceID,
        firstDisplay: DisplayID,
        secondDisplay: DisplayID,
        firstWindow: WindowID,
        secondWindow: WindowID
    ) {
        let firstSpace = SpaceID(raw: 1)
        let secondSpace = SpaceID(raw: 2)
        let firstDisplay = DisplayID(raw: 1)
        let secondDisplay = DisplayID(raw: 2)
        let firstWindow = WindowID(raw: 1)
        let secondWindow = WindowID(raw: 2)
        let displays = [
            firstDisplay: DisplayInfo(
                id: firstDisplay,
                slot: 0,
                fingerprint: nil,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
            ),
            secondDisplay: DisplayInfo(
                id: secondDisplay,
                slot: 1,
                fingerprint: nil,
                frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
                visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
            )
        ]
        let windows = [
            firstWindow: metadata(firstWindow, x: 0),
            secondWindow: metadata(secondWindow, x: 1000)
        ]
        return (
            World(
                displays: displays,
                activeSpace: firstSpace,
                activeSpaceByDisplay: [firstDisplay: firstSpace, secondDisplay: secondSpace],
                spaces: [
                    firstSpace: SpaceState(
                        id: firstSpace,
                        displays: [firstDisplay: DisplaySpaceState(displayID: firstDisplay, tree: .leaf(firstWindow), floating: [])],
                        focused: firstWindow
                    ),
                    secondSpace: SpaceState(
                        id: secondSpace,
                        displays: [secondDisplay: DisplaySpaceState(displayID: secondDisplay, tree: .leaf(secondWindow), floating: [])],
                        focused: secondWindow
                    )
                ],
                windows: windows,
                windowDisplay: [firstWindow: firstDisplay, secondWindow: secondDisplay],
                windowSpace: [firstWindow: firstSpace, secondWindow: secondSpace],
                windowConstraints: [
                    firstWindow: WindowConstraints(minWidth: 400),
                    secondWindow: WindowConstraints(minWidth: 500)
                ],
                pendingRules: [:],
                config: .default
            ),
            firstSpace,
            secondSpace,
            firstDisplay,
            secondDisplay,
            firstWindow,
            secondWindow
        )
    }

    private func metadata(_ id: WindowID, x: CGFloat) -> WindowMetadata {
        WindowMetadata(
            id: id,
            bundleID: BundleID(raw: "com.example.\(id.raw)"),
            title: "Window \(id.raw)",
            role: "AXWindow",
            pid: ProcessID(Int32(id.raw)),
            frame: CGRect(x: x, y: 0, width: 1000, height: 800),
            isResizable: true,
            isMinimized: false
        )
    }
}
