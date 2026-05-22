import Foundation
import NarwhalAppSupport

enum StartupCommand: Equatable {
    case normal
    case checkConfig
    case checkEnvironment
    case pushLeft
    case focusedWindow
    case checkAccessibility
}

enum StartupArgumentError: Error, CustomStringConvertible, Equatable {
    case missingRestoreStatePath
    case missingDebugFailServiceStartName

    var description: String {
        switch self {
        case .missingRestoreStatePath:
            return "--restore-state requires a file path"
        case .missingDebugFailServiceStartName:
            return "--debug-fail-service-start requires a service name"
        }
    }
}

enum ServiceStartupRequestError: Error, CustomStringConvertible, Equatable {
    case startupArgument(StartupArgumentError)
    case failureInjection(ServiceStartFailureInjectionError)

    var description: String {
        switch self {
        case .startupArgument(let error):
            return error.description
        case .failureInjection(let error):
            return error.description
        }
    }
}

struct StartupArguments {
    let raw: [String]

    static var current: StartupArguments {
        StartupArguments(raw: ProcessInfo.processInfo.arguments)
    }

    var verifierFlag: String? {
        raw.first { $0.hasPrefix("--verify-") }
    }

    var command: StartupCommand {
        if raw.contains("--check-config") { return .checkConfig }
        if raw.contains("--check-environment") { return .checkEnvironment }
        if raw.contains("--push-left") { return .pushLeft }
        if raw.contains("--focused-window") { return .focusedWindow }
        if raw.contains("--check-accessibility") { return .checkAccessibility }
        return .normal
    }

    var restoreStateURL: Result<URL, StartupArgumentError> {
        guard let path = value(after: "--restore-state") else {
            return raw.contains("--restore-state")
                ? .failure(.missingRestoreStatePath)
                : .success(RestoreManager.defaultURL)
        }
        return .success(URL(fileURLWithPath: path).standardizedFileURL)
    }

    var startupConfigRequest: Result<StartupConfigRequest, StartupConfigError> {
        guard let path = value(after: "--config") else {
            return raw.contains("--config")
                ? .failure(.missingConfigPathArgument)
                : .success(StartupConfigRequest(
                    url: StartupConfigLoader.defaultUserConfigURL,
                    missingFilePolicy: .useBuiltInDefault
                ))
        }
        return .success(StartupConfigRequest(
            url: URL(fileURLWithPath: path).standardizedFileURL,
            missingFilePolicy: .fail
        ))
    }

    func serviceStartSteps(_ steps: [ServiceStartStep]) -> Result<[ServiceStartStep], ServiceStartupRequestError> {
        switch debugServiceStartFailureName {
        case .success(let failureTarget):
            return NarwhalAppSupport.serviceStartSteps(steps, injectingFailureAt: failureTarget)
                .mapError(ServiceStartupRequestError.failureInjection)
        case .failure(let error):
            return .failure(.startupArgument(error))
        }
    }

    private var debugServiceStartFailureName: Result<String?, StartupArgumentError> {
        guard let name = value(after: "--debug-fail-service-start") else {
            return raw.contains("--debug-fail-service-start")
                ? .failure(.missingDebugFailServiceStartName)
                : .success(nil)
        }
        return .success(name)
    }

    private func value(after flag: String) -> String? {
        guard let index = raw.firstIndex(of: flag) else { return nil }
        let valueIndex = raw.index(after: index)
        guard raw.indices.contains(valueIndex) else { return nil }
        return raw[valueIndex]
    }
}
