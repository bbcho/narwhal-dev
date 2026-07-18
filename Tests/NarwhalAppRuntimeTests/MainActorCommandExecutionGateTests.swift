import Testing
@testable import NarwhalAppRuntime

@Suite("Main-actor command execution gate")
struct MainActorCommandExecutionGateTests {
    @Test("Suspending commands execute serially in arrival order")
    @MainActor
    func serializesSuspendingCommands() async {
        let gate = MainActorCommandExecutionGate()
        var events: [String] = []

        let first = Task { @MainActor in
            await gate.perform {
                events.append("first-start")
                try? await Task.sleep(nanoseconds: 40_000_000)
                events.append("first-end")
                return 1
            }
        }
        while events.isEmpty {
            await Task.yield()
        }

        let second = Task { @MainActor in
            await gate.perform {
                events.append("second-start")
                await Task.yield()
                events.append("second-end")
                return 2
            }
        }
        let third = Task { @MainActor in
            await gate.perform {
                events.append("third-start")
                events.append("third-end")
                return 3
            }
        }
        events.append("unrelated-main-actor-work")

        #expect(await first.value == 1)
        #expect(await second.value == 2)
        #expect(await third.value == 3)
        #expect(events == [
            "first-start", "unrelated-main-actor-work", "first-end",
            "second-start", "second-end",
            "third-start", "third-end"
        ])
    }
}
