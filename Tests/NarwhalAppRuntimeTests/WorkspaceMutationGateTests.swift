import Testing
@testable import NarwhalAppRuntime

@MainActor
@Suite("Workspace mutation gate")
struct WorkspaceMutationGateTests {
    @Test("A refresh and later command wait for a suspended frame transaction in FIFO order")
    func refreshWaitsForTransaction() async {
        let gate = WorkspaceMutationGate()
        var releaseTransaction: CheckedContinuation<Void, Never>?
        var events: [String] = []

        let transaction = Task { @MainActor in
            await gate.perform {
                events.append("transaction-start")
                await withCheckedContinuation { continuation in
                    releaseTransaction = continuation
                }
                events.append("transaction-end")
            }
        }
        while releaseTransaction == nil {
            await Task.yield()
        }

        let refresh = Task { @MainActor in
            await gate.perform {
                events.append("refresh")
            }
        }
        await Task.yield()
        let command = Task { @MainActor in
            await gate.perform {
                events.append("command")
            }
        }
        await Task.yield()

        #expect(gate.isExecutingForVerification)
        #expect(events == ["transaction-start"])

        releaseTransaction?.resume()
        await transaction.value
        await refresh.value
        await command.value

        #expect(!gate.isExecutingForVerification)
        #expect(events == [
            "transaction-start",
            "transaction-end",
            "refresh",
            "command",
        ])
    }
}
