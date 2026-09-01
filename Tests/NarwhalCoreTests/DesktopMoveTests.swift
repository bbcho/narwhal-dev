import Testing
@testable import NarwhalCore

@Suite("Desktop movement")
struct DesktopMoveTests {
    private let spaces = [SpaceID(raw: 10), SpaceID(raw: 20), SpaceID(raw: 30)]

    @Test("Adjacent desktop follows row order")
    func adjacentDesktopFollowsRowOrder() throws {
        #expect(try adjacentDesktopSpace(in: spaces, active: SpaceID(raw: 20), direction: .left).get() == SpaceID(raw: 10))
        #expect(try adjacentDesktopSpace(in: spaces, active: SpaceID(raw: 20), direction: .right).get() == SpaceID(raw: 30))
    }

    @Test("Desktop edge rejects movement past the row")
    func desktopEdgeRejectsMovement() {
        #expect(adjacentDesktopSpace(in: spaces, active: SpaceID(raw: 10), direction: .left) == .failure(.noAdjacentDesktop(.left)))
        #expect(adjacentDesktopSpace(in: spaces, active: SpaceID(raw: 30), direction: .right) == .failure(.noAdjacentDesktop(.right)))
    }

    @Test("Unknown active desktop is rejected")
    func unknownActiveDesktopIsRejected() {
        #expect(adjacentDesktopSpace(in: spaces, active: SpaceID(raw: 99), direction: .right) == .failure(.activeDesktopMissing))
    }
}
