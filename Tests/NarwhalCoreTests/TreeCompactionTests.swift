import Testing
@testable import NarwhalCore

@Suite("Tree compaction")
struct TreeCompactionTests {
    private let a = WindowID(raw: 1)
    private let c = WindowID(raw: 3)

    @Test("Re-pushing one window keeps an unrelated branch's empty slot and weights")
    func repushKeepsUnrelatedEmptySlot() throws {
        let leftColumn = Node.split(try Split.create(axis: .vertical, cells: [
            try Cell.create(weight: 1.5, node: .leaf(a)).get(),
            try Cell.create(weight: 0.5, node: .void).get()
        ]).get())
        let tree = Node.split(try Split.create(axis: .horizontal, cells: [
            try Cell.create(weight: 1, node: leftColumn).get(),
            try Cell.create(weight: 1, node: .leaf(c)).get()
        ]).get())

        let pushed = pushIntoTree(c, .right, tree)

        guard case .split(let root) = pushed else {
            Issue.record("Expected a split root, got \(pushed)")
            return
        }
        #expect(root.cells.first?.node == leftColumn)
        #expect(occupiedWindows(in: pushed).sorted { $0.raw < $1.raw } == [a, c])
    }
}
