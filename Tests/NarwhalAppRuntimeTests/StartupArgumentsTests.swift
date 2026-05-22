import Foundation
import NarwhalAppSupport
import Testing
@testable import NarwhalAppRuntime

@Suite("Startup arguments")
struct StartupArgumentsTests {
    @Test("Default startup arguments use normal mode and default paths")
    func defaults() throws {
        let arguments = StartupArguments(raw: ["NarwhalApp"])

        #expect(arguments.command == .normal)
        #expect(arguments.verifierFlag == nil)

        let restoreURL = try arguments.restoreStateURL.get()
        #expect(restoreURL == RestoreManager.defaultURL)

        let request = try arguments.startupConfigRequest.get()
        #expect(request.url == StartupConfigLoader.defaultUserConfigURL)
        #expect(request.missingFilePolicy == .useBuiltInDefault)
    }

    @Test("Explicit file arguments are standardized")
    func explicitFileArguments() throws {
        let arguments = StartupArguments(raw: [
            "NarwhalApp",
            "--restore-state", "/tmp/../tmp/narwhal-state.json",
            "--config", "/tmp/../tmp/init.lua"
        ])

        let restoreURL = try arguments.restoreStateURL.get()
        #expect(restoreURL.path == "/tmp/narwhal-state.json")

        let request = try arguments.startupConfigRequest.get()
        #expect(request.url.path == "/tmp/init.lua")
        #expect(request.missingFilePolicy == .fail)
    }

    @Test("Missing valued startup flags fail explicitly")
    func missingValuedFlags() {
        #expect(StartupArguments(raw: ["NarwhalApp", "--restore-state"]).restoreStateURL.failure == .missingRestoreStatePath)

        #expect(StartupArguments(raw: ["NarwhalApp", "--config"]).startupConfigRequest.isMissingConfigPathArgument)

        let steps = StartupArguments(raw: ["NarwhalApp", "--debug-fail-service-start"])
            .serviceStartSteps([ServiceStartStep(name: "hotkeys") { {} }])
        #expect(steps.failure == .startupArgument(.missingDebugFailServiceStartName))
    }

    @Test("Startup command preserves existing flag precedence")
    func commandPrecedence() {
        #expect(StartupArguments(raw: ["NarwhalApp", "--check-config", "--check-environment"]).command == .checkConfig)
        #expect(StartupArguments(raw: ["NarwhalApp", "--check-environment", "--push-left"]).command == .checkEnvironment)
        #expect(StartupArguments(raw: ["NarwhalApp", "--push-left", "--focused-window"]).command == .pushLeft)
        #expect(StartupArguments(raw: ["NarwhalApp", "--focused-window", "--check-accessibility"]).command == .focusedWindow)
        #expect(StartupArguments(raw: ["NarwhalApp", "--check-accessibility"]).command == .checkAccessibility)
    }

    @Test("Startup service failure injection validates service names")
    func serviceFailureInjection() throws {
        let steps = [
            ServiceStartStep(name: "menubar") { {} },
            ServiceStartStep(name: "hotkeys") { {} }
        ]

        let injected = try StartupArguments(
            raw: ["NarwhalApp", "--debug-fail-service-start", "hotkeys"]
        ).serviceStartSteps(steps).get()
        #expect(injected.map(\.name) == ["menubar", "hotkeys"])

        let unknown = StartupArguments(raw: ["NarwhalApp", "--debug-fail-service-start", "missing"])
            .serviceStartSteps(steps)
            .failure
        #expect(unknown == .failureInjection(.unknownService(requested: "missing", available: ["menubar", "hotkeys"])))
    }

    @Test("Verifier flag selects the first verifier argument")
    func verifierFlag() {
        let arguments = StartupArguments(raw: ["NarwhalApp", "--other", "--verify-focus-border", "--verify-overlay"])
        #expect(arguments.verifierFlag == "--verify-focus-border")
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

private extension Result where Failure == StartupConfigError {
    var isMissingConfigPathArgument: Bool {
        guard case .failure(.missingConfigPathArgument) = self else { return false }
        return true
    }
}
