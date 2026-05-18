public typealias ServiceStop = @MainActor () -> Void
public typealias ServiceStart = @MainActor () throws -> ServiceStop

public struct ServiceStartStep {
    public let name: String
    private let startEffect: ServiceStart

    public init(name: String, start: @escaping ServiceStart) {
        self.name = name
        self.startEffect = start
    }

    @MainActor
    fileprivate func start() throws -> ServiceHandle {
        ServiceHandle(name: name, stop: try startEffect())
    }
}

public struct ServiceStartupError: Error, CustomStringConvertible {
    public let service: String
    public let startedServices: [String]
    public let underlyingError: Error

    public var description: String {
        let started = startedServices.isEmpty ? "nothing" : startedServices.joined(separator: ", ")
        return "service startup failed at \(service) after starting \(started): \(describe(underlyingError))"
    }

    public init(service: String, startedServices: [String], underlyingError: Error) {
        self.service = service
        self.startedServices = startedServices
        self.underlyingError = underlyingError
    }
}

public enum ServiceStartFailureInjectionError: Error, Equatable, CustomStringConvertible {
    case injected(service: String)
    case unknownService(requested: String, available: [String])

    public var description: String {
        switch self {
        case .injected(let service):
            return "injected startup failure at service \(service)"
        case .unknownService(let requested, let available):
            let services = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "unknown service startup failure target \(requested); available services: \(services)"
        }
    }
}

@MainActor
public final class RunningServices {
    private var handles: [ServiceHandle]

    public var serviceNames: [String] {
        handles.map(\.name)
    }

    fileprivate init(handles: [ServiceHandle]) {
        self.handles = handles
    }

    public func stopAll() {
        let active = Array(handles.reversed())
        handles.removeAll()
        for handle in active {
            handle.stop()
        }
    }
}

@MainActor
public func startServiceSequence(_ steps: [ServiceStartStep]) -> Result<RunningServices, ServiceStartupError> {
    var handles: [ServiceHandle] = []

    for step in steps {
        do {
            handles.append(try step.start())
        } catch {
            let startedServices = handles.map(\.name)
            RunningServices(handles: handles).stopAll()
            return .failure(ServiceStartupError(
                service: step.name,
                startedServices: startedServices,
                underlyingError: error
            ))
        }
    }

    return .success(RunningServices(handles: handles))
}

public func serviceStartSteps(
    _ steps: [ServiceStartStep],
    injectingFailureAt requestedService: String?
) -> Result<[ServiceStartStep], ServiceStartFailureInjectionError> {
    guard let requestedService else {
        return .success(steps)
    }

    let available = steps.map(\.name)
    guard available.contains(requestedService) else {
        return .failure(.unknownService(requested: requestedService, available: available))
    }

    return .success(steps.map { step in
        guard step.name == requestedService else { return step }
        return ServiceStartStep(name: step.name) {
            throw ServiceStartFailureInjectionError.injected(service: step.name)
        }
    })
}

private struct ServiceHandle {
    let name: String
    private let stopEffect: ServiceStop

    init(name: String, stop: @escaping ServiceStop) {
        self.name = name
        self.stopEffect = stop
    }

    @MainActor
    func stop() {
        stopEffect()
    }
}

private func describe(_ error: Error) -> String {
    if let custom = error as? CustomStringConvertible {
        return custom.description
    }
    return String(describing: error)
}
