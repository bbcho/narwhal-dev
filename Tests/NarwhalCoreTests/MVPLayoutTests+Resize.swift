import CoreGraphics
import Testing
@testable import NarwhalCore

extension MVPLayoutTests {
    @Test("Balance tree normalizes every split weight without changing slots")
    func balanceTreeNormalizesEverySplitWeight() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 3, node: .leaf(first)),
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 4, node: .leaf(second)),
                try cell(weight: 2, node: .void)
            ])))
        ]))

        let balanced = balanceTree(tree)

        #expect(balanced == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(second)),
                try cell(weight: 1, node: .void)
            ])))
        ])))
        #expect(slots(in: balanced) == [
            TreeSlot(path: [0], occupancy: .occupied(first)),
            TreeSlot(path: [1, 0], occupancy: .occupied(second)),
            TreeSlot(path: [1, 1], occupancy: .empty)
        ])

        let result = frames(for: balanced)
        #expect(result[first] == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(result[second] == CGRect(x: 600, y: 0, width: 600, height: 400))
    }

    @Test("Apply balance normalizes one Space while preserving world metadata")
    func applyBalanceNormalizesSelectedSpaceOnly() throws {
        let display = DisplayID(raw: 1)
        let selectedSpace = SpaceID(raw: 1)
        let otherSpace = SpaceID(raw: 2)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let floating = WindowID(raw: 3)
        let selectedTree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 5, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ]))
        let otherTree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 7, node: .leaf(first)),
            try cell(weight: 1, node: .void)
        ]))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: selectedSpace,
            spaces: [
                selectedSpace: SpaceState(
                    id: selectedSpace,
                    displays: [display: DisplaySpaceState(displayID: display, tree: selectedTree, floating: [floating])],
                    focused: second
                ),
                otherSpace: SpaceState(
                    id: otherSpace,
                    displays: [display: DisplaySpaceState(displayID: display, tree: otherTree, floating: [])],
                    focused: first
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second),
                floating: metadata(for: floating)
            ],
            windowDisplay: [
                first: display,
                second: display,
                floating: display
            ],
            windowConstraints: [second: WindowConstraints(minWidth: 500)],
            pendingRules: [floating: .forceFloat],
            config: .default
        )

        let next = try requireWorld(apply(.balance(selectedSpace), to: world), "Expected balance to succeed")

        #expect(next.spaces[selectedSpace]?.displays[display]?.tree == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ])))
        #expect(next.spaces[selectedSpace]?.displays[display]?.floating == [floating])
        #expect(next.spaces[selectedSpace]?.focused == second)
        #expect(next.spaces[otherSpace] == world.spaces[otherSpace])
        #expect(next.displays == world.displays)
        #expect(next.activeSpace == world.activeSpace)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
    }

    @Test("Apply balance rejects missing Spaces")
    func applyBalanceRejectsMissingSpace() throws {
        let missing = SpaceID(raw: 99)

        #expect(apply(.balance(missing), to: World.empty) == .failure(.spaceNotFound(missing)))
    }

    @Test("Resize split grows the focused cell toward the requested neighbor")
    func resizeSplitGrowsFocusedCellTowardNeighbor() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ]))

        let resized = try requireSuccess(
            resizeSplitInTree(first, .right, delta: 0.5, tree),
            "Expected resize to succeed"
        )

        #expect(resized == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1.5, node: .leaf(first)),
            try cell(weight: 0.5, node: .leaf(second))
        ])))
        #expect(slots(in: resized) == [
            TreeSlot(path: [0], occupancy: .occupied(first)),
            TreeSlot(path: [1], occupancy: .occupied(second))
        ])

        let result = frames(for: resized)
        #expect(result[first] == CGRect(x: 0, y: 0, width: 900, height: 800))
        #expect(result[second] == CGRect(x: 900, y: 0, width: 300, height: 800))
    }

    @Test("Resize split chooses the innermost matching ancestor split")
    func resizeSplitChoosesInnermostMatchingAncestor() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let third = WindowID(raw: 3)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(first)),
                try cell(weight: 1, node: .leaf(third))
            ]))),
            try cell(weight: 1, node: .leaf(second))
        ]))

        let resizedDown = try requireSuccess(
            resizeSplitInTree(first, .down, delta: 0.25, tree),
            "Expected vertical resize to succeed"
        )
        let resizedRight = try requireSuccess(
            resizeSplitInTree(first, .right, delta: 0.5, tree),
            "Expected ancestor horizontal resize to succeed"
        )

        #expect(resizedDown == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1.25, node: .leaf(first)),
                try cell(weight: 0.75, node: .leaf(third))
            ]))),
            try cell(weight: 1, node: .leaf(second))
        ])))
        #expect(resizedRight == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1.5, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(first)),
                try cell(weight: 1, node: .leaf(third))
            ]))),
            try cell(weight: 0.5, node: .leaf(second))
        ])))

        let downFrames = frames(for: resizedDown)
        #expect(downFrames[first] == CGRect(x: 0, y: 0, width: 600, height: 500))
        #expect(downFrames[third] == CGRect(x: 0, y: 500, width: 600, height: 300))
        #expect(downFrames[second] == CGRect(x: 600, y: 0, width: 600, height: 800))

        let rightFrames = frames(for: resizedRight)
        #expect(rightFrames[first] == CGRect(x: 0, y: 0, width: 900, height: 400))
        #expect(rightFrames[third] == CGRect(x: 0, y: 400, width: 900, height: 400))
        #expect(rightFrames[second] == CGRect(x: 900, y: 0, width: 300, height: 800))
    }

    @Test("Resize split handles A spanning left with B over C and mirrored right span")
    func resizeSplitHandlesTwoRowSpansAndMirrors() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let leftSpan = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(a)),
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(b)),
                try cell(weight: 1, node: .leaf(c))
            ])))
        ]))
        let rightSpan = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(b)),
                try cell(weight: 1, node: .leaf(c))
            ]))),
            try cell(weight: 1, node: .leaf(a))
        ]))

        let leftFrames = frames(for: leftSpan)
        #expect(leftFrames[a] == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(leftFrames[b] == CGRect(x: 600, y: 0, width: 600, height: 400))
        #expect(leftFrames[c] == CGRect(x: 600, y: 400, width: 600, height: 400))

        let grownLeftSpan = try requireSuccess(
            resizeSplitInTree(a, .right, delta: 0.25, leftSpan),
            "Expected left spanning tile to grow toward right stack"
        )
        let grownLeftFrames = frames(for: grownLeftSpan)
        #expect(grownLeftFrames[a] == CGRect(x: 0, y: 0, width: 750, height: 800))
        #expect(grownLeftFrames[b] == CGRect(x: 750, y: 0, width: 450, height: 400))
        #expect(grownLeftFrames[c] == CGRect(x: 750, y: 400, width: 450, height: 400))

        let grownTopRight = try requireSuccess(
            resizeSplitInTree(b, .down, delta: 0.25, leftSpan),
            "Expected top-right tile to grow toward bottom-right tile"
        )
        let grownTopFrames = frames(for: grownTopRight)
        #expect(grownTopFrames[a] == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(grownTopFrames[b] == CGRect(x: 600, y: 0, width: 600, height: 500))
        #expect(grownTopFrames[c] == CGRect(x: 600, y: 500, width: 600, height: 300))

        let rightFrames = frames(for: rightSpan)
        #expect(rightFrames[b] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(rightFrames[c] == CGRect(x: 0, y: 400, width: 600, height: 400))
        #expect(rightFrames[a] == CGRect(x: 600, y: 0, width: 600, height: 800))

        let grownRightSpan = try requireSuccess(
            resizeSplitInTree(a, .left, delta: 0.25, rightSpan),
            "Expected right spanning tile to grow toward left stack"
        )
        let grownRightFrames = frames(for: grownRightSpan)
        #expect(grownRightFrames[b] == CGRect(x: 0, y: 0, width: 450, height: 400))
        #expect(grownRightFrames[c] == CGRect(x: 0, y: 400, width: 450, height: 400))
        #expect(grownRightFrames[a] == CGRect(x: 450, y: 0, width: 750, height: 800))
    }

    @Test("Resize split handles A column with B spanning over C and D and mirrored column")
    func resizeSplitHandlesColumnAndRowSpansWithMirrors() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let d = WindowID(raw: 4)
        let rightComposite = Node.split(try split(axis: .vertical, cells: [
            try cell(weight: 1, node: .leaf(b)),
            try cell(weight: 1, node: .split(try split(axis: .horizontal, cells: [
                try cell(weight: 1, node: .leaf(c)),
                try cell(weight: 1, node: .leaf(d))
            ])))
        ]))
        let leftSpan = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(a)),
            try cell(weight: 2, node: rightComposite)
        ]))
        let rightSpan = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 2, node: rightComposite),
            try cell(weight: 1, node: .leaf(a))
        ]))

        let leftFrames = frames(for: leftSpan)
        #expect(leftFrames[a] == CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(leftFrames[b] == CGRect(x: 400, y: 0, width: 800, height: 400))
        #expect(leftFrames[c] == CGRect(x: 400, y: 400, width: 400, height: 400))
        #expect(leftFrames[d] == CGRect(x: 800, y: 400, width: 400, height: 400))

        let grownLeftSpan = try requireSuccess(
            resizeSplitInTree(a, .right, delta: 0.5, leftSpan),
            "Expected left spanning tile to grow toward right composite"
        )
        let grownLeftFrames = frames(for: grownLeftSpan)
        #expect(grownLeftFrames[a] == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(grownLeftFrames[b] == CGRect(x: 600, y: 0, width: 600, height: 400))
        #expect(grownLeftFrames[c] == CGRect(x: 600, y: 400, width: 300, height: 400))
        #expect(grownLeftFrames[d] == CGRect(x: 900, y: 400, width: 300, height: 400))

        let grownTop = try requireSuccess(
            resizeSplitInTree(b, .down, delta: 0.25, leftSpan),
            "Expected top spanning tile to grow toward lower row"
        )
        let grownTopFrames = frames(for: grownTop)
        #expect(grownTopFrames[a] == CGRect(x: 0, y: 0, width: 400, height: 800))
        #expect(grownTopFrames[b] == CGRect(x: 400, y: 0, width: 800, height: 500))
        #expect(grownTopFrames[c] == CGRect(x: 400, y: 500, width: 400, height: 300))
        #expect(grownTopFrames[d] == CGRect(x: 800, y: 500, width: 400, height: 300))

        let rightFrames = frames(for: rightSpan)
        #expect(rightFrames[b] == CGRect(x: 0, y: 0, width: 800, height: 400))
        #expect(rightFrames[c] == CGRect(x: 0, y: 400, width: 400, height: 400))
        #expect(rightFrames[d] == CGRect(x: 400, y: 400, width: 400, height: 400))
        #expect(rightFrames[a] == CGRect(x: 800, y: 0, width: 400, height: 800))

        let grownRightSpan = try requireSuccess(
            resizeSplitInTree(a, .left, delta: 0.5, rightSpan),
            "Expected right spanning tile to grow toward left composite"
        )
        let grownRightFrames = frames(for: grownRightSpan)
        #expect(grownRightFrames[b] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(grownRightFrames[c] == CGRect(x: 0, y: 400, width: 300, height: 400))
        #expect(grownRightFrames[d] == CGRect(x: 300, y: 400, width: 300, height: 400))
        #expect(grownRightFrames[a] == CGRect(x: 600, y: 0, width: 600, height: 800))
    }

    @Test("Resize split handles wide irregular A and B spans over E D C and mirrored spans")
    func resizeSplitHandlesWideIrregularSpansAndMirrors() throws {
        let a = WindowID(raw: 1)
        let b = WindowID(raw: 2)
        let c = WindowID(raw: 3)
        let d = WindowID(raw: 4)
        let e = WindowID(raw: 5)
        let rightComposite = Node.split(try split(axis: .vertical, cells: [
            try cell(weight: 1, node: .leaf(b)),
            try cell(weight: 1, node: .split(try split(axis: .horizontal, cells: [
                try cell(weight: 1, node: .leaf(e)),
                try cell(weight: 1, node: .leaf(d)),
                try cell(weight: 2, node: .leaf(c))
            ])))
        ]))
        let leftSpan = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 4, node: .leaf(a)),
            try cell(weight: 4, node: rightComposite)
        ]))
        let rightSpan = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 4, node: rightComposite),
            try cell(weight: 4, node: .leaf(a))
        ]))
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 800)

        let leftFrames = frames(for: leftSpan, frame: frame)
        #expect(leftFrames[a] == CGRect(x: 0, y: 0, width: 800, height: 800))
        #expect(leftFrames[b] == CGRect(x: 800, y: 0, width: 800, height: 400))
        #expect(leftFrames[e] == CGRect(x: 800, y: 400, width: 200, height: 400))
        #expect(leftFrames[d] == CGRect(x: 1000, y: 400, width: 200, height: 400))
        #expect(leftFrames[c] == CGRect(x: 1200, y: 400, width: 400, height: 400))

        let grownLeftSpan = try requireSuccess(
            resizeSplitInTree(a, .right, delta: 1, leftSpan),
            "Expected wide left spanning tile to grow toward right composite"
        )
        let grownLeftFrames = frames(for: grownLeftSpan, frame: frame)
        #expect(grownLeftFrames[a] == CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(grownLeftFrames[b] == CGRect(x: 1000, y: 0, width: 600, height: 400))
        #expect(grownLeftFrames[e] == CGRect(x: 1000, y: 400, width: 150, height: 400))
        #expect(grownLeftFrames[d] == CGRect(x: 1150, y: 400, width: 150, height: 400))
        #expect(grownLeftFrames[c] == CGRect(x: 1300, y: 400, width: 300, height: 400))

        let grownB = try requireSuccess(
            resizeSplitInTree(b, .down, delta: 0.25, leftSpan),
            "Expected wide top row to grow toward lower irregular row"
        )
        let grownBFrames = frames(for: grownB, frame: frame)
        #expect(grownBFrames[a] == CGRect(x: 0, y: 0, width: 800, height: 800))
        #expect(grownBFrames[b] == CGRect(x: 800, y: 0, width: 800, height: 500))
        #expect(grownBFrames[e] == CGRect(x: 800, y: 500, width: 200, height: 300))
        #expect(grownBFrames[d] == CGRect(x: 1000, y: 500, width: 200, height: 300))
        #expect(grownBFrames[c] == CGRect(x: 1200, y: 500, width: 400, height: 300))

        let rightFrames = frames(for: rightSpan, frame: frame)
        #expect(rightFrames[b] == CGRect(x: 0, y: 0, width: 800, height: 400))
        #expect(rightFrames[e] == CGRect(x: 0, y: 400, width: 200, height: 400))
        #expect(rightFrames[d] == CGRect(x: 200, y: 400, width: 200, height: 400))
        #expect(rightFrames[c] == CGRect(x: 400, y: 400, width: 400, height: 400))
        #expect(rightFrames[a] == CGRect(x: 800, y: 0, width: 800, height: 800))

        let grownRightSpan = try requireSuccess(
            resizeSplitInTree(a, .left, delta: 1, rightSpan),
            "Expected wide right spanning tile to grow toward left composite"
        )
        let grownRightFrames = frames(for: grownRightSpan, frame: frame)
        #expect(grownRightFrames[b] == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(grownRightFrames[e] == CGRect(x: 0, y: 400, width: 150, height: 400))
        #expect(grownRightFrames[d] == CGRect(x: 150, y: 400, width: 150, height: 400))
        #expect(grownRightFrames[c] == CGRect(x: 300, y: 400, width: 300, height: 400))
        #expect(grownRightFrames[a] == CGRect(x: 600, y: 0, width: 1000, height: 800))
    }

    @Test("Generated resize combinations keep frames non-overlapping and inside the display")
    func generatedResizeCombinationsPreserveFrameInvariants() throws {
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        var generatedCounts: Set<Int> = []
        var sequenceCountByWindowCount: [Int: Int] = [:]
        var resizeCountByWindowCount: [Int: Int] = [:]
        var sequencesWithoutResize: [String] = []
        for count in 2...6 {
            for sequence in generatedDirectionSequences(length: count) {
                generatedCounts.insert(count)
                sequenceCountByWindowCount[count, default: 0] += 1
                var tree = Node.void
                for (index, direction) in sequence.enumerated() {
                    tree = pushIntoTree(WindowID(raw: UInt32(index + 1)), direction, tree)
                }
                let windows = occupiedWindows(in: tree)
                var resizedThisSequence = 0
                for window in windows {
                    for direction in [Direction.left, .right, .up, .down] {
                        guard case .success(let resized) = resizeSplitInTree(window, direction, delta: 0.10, tree) else {
                            continue
                        }
                        let rects = Array(frames(for: resized, frame: frame).values)
                        try requireValidPartition(rects, in: frame, context: "count=\(count) sequence=\(sequence.map(\.rawValue).joined()) window=\(window.raw) direction=\(direction.rawValue)")
                        resizedThisSequence += 1
                    }
                }
                if resizedThisSequence == 0 {
                    sequencesWithoutResize.append("count=\(count) sequence=\(sequence.map(\.rawValue).joined())")
                }
                resizeCountByWindowCount[count, default: 0] += resizedThisSequence
            }
        }
        #expect(generatedCounts == Set(2...6))
        #expect(sequenceCountByWindowCount == [2: 16, 3: 64, 4: 256, 5: 1024, 6: 4096])
        #expect(sequencesWithoutResize.isEmpty, "Every generated resize sequence should expose at least one valid resize; missing=\(sequencesWithoutResize.prefix(5).joined(separator: ";"))")
        #expect(Set(resizeCountByWindowCount.keys) == Set(2...6))
        for count in 2...6 {
            #expect((resizeCountByWindowCount[count] ?? 0) >= (sequenceCountByWindowCount[count] ?? 0))
        }
    }

    @Test("Resize split rejects missing neighbor, invalid delta, and collapsing weights")
    func resizeSplitRejectsInvalidPureInputs() throws {
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let missing = WindowID(raw: 99)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ]))

        #expect(resizeSplitInTree(first, .left, delta: 0.5, tree) == .failure(.noNeighbor(.left)))
        #expect(resizeSplitInTree(first, .right, delta: .infinity, tree) == .failure(.nonFiniteDelta))
        #expect(resizeSplitInTree(first, .right, delta: 1, tree) == .failure(.nonPositiveWeight))
        #expect(resizeSplitInTree(missing, .right, delta: 0.5, tree) == .failure(.windowNotFound(missing)))
    }

    @Test("Apply resizeSplit updates active tree weights and preserves world metadata")
    func applyResizeSplitUpdatesWeightsOnly() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let floating = WindowID(raw: 3)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ]))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [floating])],
                    focused: second
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second),
                floating: metadata(for: floating)
            ],
            windowDisplay: [
                first: display,
                second: display,
                floating: display
            ],
            windowConstraints: [second: WindowConstraints(minWidth: 500)],
            pendingRules: [floating: .forceFloat],
            config: .default
        )

        let next = try requireWorld(
            apply(.resizeSplit(first, .right, delta: 0.5), to: world),
            "Expected resizeSplit to succeed"
        )
        let flattened = try requireLayout(flattenedLayout(of: next), "Expected resized layout to remain satisfiable")

        #expect(next.spaces[space]?.displays[display]?.tree == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1.5, node: .leaf(first)),
            try cell(weight: 0.5, node: .leaf(second))
        ])))
        #expect(next.spaces[space]?.displays[display]?.floating == [floating])
        #expect(next.spaces[space]?.focused == first)
        #expect(next.displays == world.displays)
        #expect(next.windows == world.windows)
        #expect(next.windowDisplay == world.windowDisplay)
        #expect(next.windowConstraints == world.windowConstraints)
        #expect(next.pendingRules == world.pendingRules)
        #expect(next.config == world.config)
        #expect(flattened.tiled[first] == CGRect(x: 0, y: 0, width: 700, height: 800))
        #expect(flattened.tiled[second] == CGRect(x: 700, y: 0, width: 500, height: 800))
    }

    @Test("Apply resizeSplit resizes Chrome over Firefox on the same side")
    func applyResizeSplitResizesChromeOverFirefox() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let chrome = WindowID(raw: 1)
        let firefox = WindowID(raw: 2)
        let companion = WindowID(raw: 3)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1, node: .leaf(chrome)),
                try cell(weight: 1, node: .leaf(firefox))
            ]))),
            try cell(weight: 1, node: .leaf(companion))
        ]))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [])],
                    focused: chrome
                )
            ],
            windows: [
                chrome: metadata(for: chrome, bundleID: "com.google.Chrome"),
                firefox: metadata(for: firefox, bundleID: "org.mozilla.firefox"),
                companion: metadata(for: companion, bundleID: "net.kovidgoyal.kitty")
            ],
            windowDisplay: [
                chrome: display,
                firefox: display,
                companion: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )

        let next = try requireWorld(
            apply(.resizeSplit(chrome, .down, delta: 0.25), to: world),
            "Expected Chrome over Firefox resize to succeed"
        )
        let flattened = try requireLayout(flattenedLayout(of: next), "Expected resized browser layout")

        #expect(next.spaces[space]?.displays[display]?.tree == Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .split(try split(axis: .vertical, cells: [
                try cell(weight: 1.25, node: .leaf(chrome)),
                try cell(weight: 0.75, node: .leaf(firefox))
            ]))),
            try cell(weight: 1, node: .leaf(companion))
        ])))
        #expect(flattened.tiled[chrome] == CGRect(x: 0, y: 0, width: 600, height: 500))
        #expect(flattened.tiled[firefox] == CGRect(x: 0, y: 500, width: 600, height: 300))
        #expect(flattened.tiled[companion] == CGRect(x: 600, y: 0, width: 600, height: 800))
    }

    @Test("Apply resizeSplit rejects invalid command state")
    func applyResizeSplitRejectsInvalidState() throws {
        let display = DisplayID(raw: 1)
        let space = SpaceID(raw: 1)
        let first = WindowID(raw: 1)
        let second = WindowID(raw: 2)
        let floating = WindowID(raw: 3)
        let fixed = WindowID(raw: 4)
        let missing = WindowID(raw: 99)
        let tree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(first)),
            try cell(weight: 1, node: .leaf(second))
        ]))
        let fixedTree = Node.split(try split(axis: .horizontal, cells: [
            try cell(weight: 1, node: .leaf(fixed)),
            try cell(weight: 1, node: .leaf(second))
        ]))
        let world = World(
            displays: [display: self.display(display, x: 0, width: 1200)],
            activeSpace: space,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: tree, floating: [floating])],
                    focused: first
                )
            ],
            windows: [
                first: metadata(for: first),
                second: metadata(for: second),
                floating: metadata(for: floating),
                fixed: metadata(for: fixed, isResizable: false)
            ],
            windowDisplay: [
                first: display,
                second: display,
                floating: display,
                fixed: display
            ],
            windowConstraints: [:],
            pendingRules: [:],
            config: .default
        )
        let nonResizableWorld = World(
            displays: world.displays,
            activeSpace: world.activeSpace,
            spaces: [
                space: SpaceState(
                    id: space,
                    displays: [display: DisplaySpaceState(displayID: display, tree: fixedTree, floating: [])],
                    focused: fixed
                )
            ],
            windows: world.windows,
            windowDisplay: world.windowDisplay,
            windowConstraints: world.windowConstraints,
            pendingRules: world.pendingRules,
            config: world.config
        )

        #expect(apply(.resizeSplit(missing, .right, delta: 0.5), to: world) == .failure(.windowNotFound(missing)))
        #expect(apply(.resizeSplit(fixed, .right, delta: 0.5), to: nonResizableWorld) == .failure(.windowNotResizable(fixed)))
        #expect(apply(.resizeSplit(floating, .right, delta: 0.5), to: world) == .failure(.windowIsFloating(floating)))
        #expect(apply(.resizeSplit(first, .left, delta: 0.5), to: world) == .failure(.noNeighbor(.left)))
        #expect(apply(.resizeSplit(first, .right, delta: .nan), to: world) == .failure(.invalidResizeDelta))
        #expect(
            apply(.resizeSplit(first, .right, delta: 1), to: world)
                == .failure(.resizeWouldCollapseSplit(first, .right))
        )
    }
}
