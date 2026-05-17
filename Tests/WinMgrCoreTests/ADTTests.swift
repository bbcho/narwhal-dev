import CoreGraphics
import Foundation
import Testing
@testable import WinMgrCore

private enum FixtureError: Error {
    case invalidJSONMutation
}

private func requireSuccess<Success, Failure: Error>(_ result: Result<Success, Failure>) throws -> Success {
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    }
}

private func overlapArea(_ lhs: ProportionalRect, _ rhs: ProportionalRect) -> Double {
    let minX = max(lhs.x, rhs.x)
    let maxX = min(lhs.x + lhs.w, rhs.x + rhs.w)
    let minY = max(lhs.y, rhs.y)
    let maxY = min(lhs.y + lhs.h, rhs.y + rhs.h)
    return max(0, maxX - minX) * max(0, maxY - minY)
}

@Suite("WinMgrCore ADTs")
struct ADTTests {
    @Test("Cell smart constructors enforce invariants")
    func cellConstructorsValidateWeights() throws {
        #expect(Cell.create(weight: .nan, node: .void) == .failure(.nonFiniteNumber("cell.weight")))
        #expect(Cell.create(weight: 0, node: .void) == .failure(.cellWeightMustBePositive))
        #expect(Cell.create(weight: -1, node: .void) == .failure(.cellWeightMustBePositive))

        let validCell = try requireSuccess(Cell.create(weight: 1, node: .void))
        #expect(Split.create(axis: .horizontal, cells: [validCell]) == .failure(.splitNeedsAtLeastTwoCells))
    }

    @Test("Stored ADTs enforce invariants at construction and decode")
    func storedConstructorsAndDecodeValidateWeights() throws {
        let validStoredCell = try requireSuccess(StoredCell.create(weight: 1, node: .void))

        #expect(StoredCell.create(weight: 0, node: .void) == .failure(.cellWeightMustBePositive))
        #expect(StoredCell.create(weight: .nan, node: .void) == .failure(.nonFiniteNumber("storedCell.weight")))
        #expect(StoredSplit.create(axis: .vertical, cells: [validStoredCell]) == .failure(.splitNeedsAtLeastTwoCells))

        let data = try JSONEncoder().encode(validStoredCell)
        guard
            let json = String(data: data, encoding: .utf8),
            let range = json.range(of: "\"weight\":1"),
            let invalidData = json
                .replacingOccurrences(of: "\"weight\":1", with: "\"weight\":0", options: [], range: range)
                .data(using: .utf8)
        else {
            throw FixtureError.invalidJSONMutation
        }

        do {
            _ = try JSONDecoder().decode(StoredCell.self, from: invalidData)
            #expect(Bool(false))
        } catch {
            #expect(String(describing: error).contains("cellWeightMustBePositive"))
        }
    }

    @Test("Default zones are non-overlapping")
    func defaultZonesDoNotOverlap() {
        for (index, first) in DefaultZones.entries.enumerated() {
            for second in DefaultZones.entries.dropFirst(index + 1) {
                #expect(overlapArea(first.bounds, second.bounds) == 0)
            }
        }
    }

    @Test("StoredWorld validation rejects invalid window references")
    func storedWorldValidationRejectsInvalidWindowReferences() {
        let invalidRef = StoredWindowRef(
            bundleID: BundleID(raw: "com.example.app"),
            title: "Window",
            role: "AXWindow",
            occurrence: -1,
            lastKnownFrame: nil
        )
        let stored = StoredWorld(
            schemaVersion: StoredWorld.currentSchemaVersion,
            activeSpace: StoredSpace(
                layouts: [
                    StoredDisplayLayout(
                        displaySlot: 0,
                        displayFingerprint: nil,
                        tree: .leaf(invalidRef),
                        floating: []
                    )
                ],
                focused: nil
            ),
            pendingRules: []
        )

        #expect(
            validateStoredWorld(stored) == .failure(.invalidStoredWorld("StoredWindowRef.occurrence must be non-negative"))
        )
    }
}
