import Testing
@testable import WinMgrAppSupport

@MainActor
@Suite("Service lifecycle orchestration")
struct ServiceLifecycleTests {
    @Test("Successful startup records handles and stops in reverse order exactly once")
    func successfulStartupStopsInReverseOrderExactlyOnce() throws {
        let recorder = EventRecorder()

        let result = startServiceSequence([
            fakeStep("menubar", recorder: recorder),
            fakeStep("hotkeys", recorder: recorder),
            fakeStep("ipc", recorder: recorder)
        ])

        let services = try requireSuccess(result)
        #expect(services.serviceNames == ["menubar", "hotkeys", "ipc"])
        #expect(recorder.events == ["start menubar", "start hotkeys", "start ipc"])

        services.stopAll()
        #expect(recorder.events == [
            "start menubar",
            "start hotkeys",
            "start ipc",
            "stop ipc",
            "stop hotkeys",
            "stop menubar"
        ])

        services.stopAll()
        #expect(recorder.events == [
            "start menubar",
            "start hotkeys",
            "start ipc",
            "stop ipc",
            "stop hotkeys",
            "stop menubar"
        ])
    }

    @Test("Failed startup rolls back already-started services in reverse order")
    func failedStartupRollsBackAlreadyStartedServices() throws {
        let recorder = EventRecorder()

        let result = startServiceSequence([
            fakeStep("menubar", recorder: recorder),
            fakeStep("hotkeys", recorder: recorder),
            failingStep("ipc", recorder: recorder),
            fakeStep("dragZones", recorder: recorder)
        ])

        let error = try requireFailure(result)
        #expect(error.service == "ipc")
        #expect(error.startedServices == ["menubar", "hotkeys"])
        #expect(error.description == "service startup failed at ipc after starting menubar, hotkeys: boom")
        #expect(recorder.events == [
            "start menubar",
            "start hotkeys",
            "start ipc",
            "stop hotkeys",
            "stop menubar"
        ])
    }

    @Test("Empty startup sequence has no effects")
    func emptyStartupSequenceHasNoEffects() throws {
        let services = try requireSuccess(startServiceSequence([]))
        #expect(services.serviceNames == [])
        services.stopAll()
        #expect(services.serviceNames == [])
    }

    private func fakeStep(_ name: String, recorder: EventRecorder) -> ServiceStartStep {
        ServiceStartStep(name: name) {
            recorder.events.append("start \(name)")
            return {
                recorder.events.append("stop \(name)")
            }
        }
    }

    private func failingStep(_ name: String, recorder: EventRecorder) -> ServiceStartStep {
        ServiceStartStep(name: name) {
            recorder.events.append("start \(name)")
            throw FakeStartupError.boom
        }
    }

    private func requireSuccess(
        _ result: Result<RunningServices, ServiceStartupError>
    ) throws -> RunningServices {
        switch result {
        case .success(let services):
            return services
        case .failure(let error):
            Issue.record("Expected startup success, got \(error.description)")
            throw error
        }
    }

    private func requireFailure(
        _ result: Result<RunningServices, ServiceStartupError>
    ) throws -> ServiceStartupError {
        switch result {
        case .success:
            let error = FakeStartupError.unexpectedSuccess
            Issue.record("Expected startup failure")
            throw error
        case .failure(let error):
            return error
        }
    }
}

private final class EventRecorder {
    var events: [String] = []
}

private enum FakeStartupError: Error, CustomStringConvertible {
    case boom
    case unexpectedSuccess

    var description: String {
        switch self {
        case .boom:
            return "boom"
        case .unexpectedSuccess:
            return "unexpected success"
        }
    }
}
