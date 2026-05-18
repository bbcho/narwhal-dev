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

    @Test("Injected startup failure fails before the named service effect runs")
    func injectedStartupFailureFailsBeforeNamedServiceEffectRuns() throws {
        let recorder = EventRecorder()
        let steps = [
            fakeStep("menubar", recorder: recorder),
            fakeStep("hotkeys", recorder: recorder),
            fakeStep("ipcServer", recorder: recorder),
            fakeStep("dragZones", recorder: recorder)
        ]

        let injected = try requireInjectionSuccess(serviceStartSteps(steps, injectingFailureAt: "ipcServer"))
        let error = try requireFailure(startServiceSequence(injected))

        #expect(error.service == "ipcServer")
        #expect(error.startedServices == ["menubar", "hotkeys"])
        #expect(error.description == "service startup failed at ipcServer after starting menubar, hotkeys: injected startup failure at service ipcServer")
        #expect(recorder.events == [
            "start menubar",
            "start hotkeys",
            "stop hotkeys",
            "stop menubar"
        ])
    }

    @Test("Injected startup failure rejects unknown service names")
    func injectedStartupFailureRejectsUnknownServiceNames() throws {
        let recorder = EventRecorder()
        let steps = [
            fakeStep("menubar", recorder: recorder),
            fakeStep("hotkeys", recorder: recorder)
        ]

        let error = try requireInjectionFailure(serviceStartSteps(steps, injectingFailureAt: "ipcServer"))

        #expect(error == .unknownService(requested: "ipcServer", available: ["menubar", "hotkeys"]))
        #expect(error.description == "unknown service startup failure target ipcServer; available services: menubar, hotkeys")
        #expect(recorder.events == [])
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

    private func requireInjectionSuccess(
        _ result: Result<[ServiceStartStep], ServiceStartFailureInjectionError>
    ) throws -> [ServiceStartStep] {
        switch result {
        case .success(let steps):
            return steps
        case .failure(let error):
            Issue.record("Expected injection success, got \(error.description)")
            throw error
        }
    }

    private func requireInjectionFailure(
        _ result: Result<[ServiceStartStep], ServiceStartFailureInjectionError>
    ) throws -> ServiceStartFailureInjectionError {
        switch result {
        case .success:
            let error = FakeStartupError.unexpectedSuccess
            Issue.record("Expected injection failure")
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
