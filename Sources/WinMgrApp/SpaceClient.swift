import Darwin
import WinMgrCore

enum SpaceClientError: Error, Equatable, CustomStringConvertible {
    case symbolUnavailable(String)
    case connectionUnavailable
    case activeSpaceUnavailable

    var description: String {
        switch self {
        case .symbolUnavailable(let symbol):
            return "private CoreGraphics symbol unavailable: \(symbol)"
        case .connectionUnavailable:
            return "CoreGraphics connection unavailable"
        case .activeSpaceUnavailable:
            return "CGSGetActiveSpace returned 0"
        }
    }
}

struct SpaceClient {
    private let symbols: SpaceSymbols

    init(symbols: SpaceSymbols = .live) {
        self.symbols = symbols
    }

    func activeSpaceID() -> Result<SpaceID, SpaceClientError> {
        guard let getActiveSpace = symbols.getActiveSpace else {
            return .failure(.symbolUnavailable("CGSGetActiveSpace"))
        }
        guard let connectionID = symbols.connectionID() else {
            return .failure(.connectionUnavailable)
        }

        let raw = getActiveSpace(connectionID)
        guard raw != 0 else {
            return .failure(.activeSpaceUnavailable)
        }
        return .success(SpaceID(raw: raw))
    }
}

typealias CGSConnectionID = Int32
typealias CGSGetActiveSpaceFunction = @convention(c) (CGSConnectionID) -> UInt64
typealias CGSConnectionIDFunction = @convention(c) () -> CGSConnectionID

struct SpaceSymbols {
    static let live = SpaceSymbols(
        getActiveSpace: loadSymbol("CGSGetActiveSpace", as: CGSGetActiveSpaceFunction.self),
        mainConnectionID: loadSymbol("CGSMainConnectionID", as: CGSConnectionIDFunction.self),
        defaultConnection: loadSymbol("_CGSDefaultConnection", as: CGSConnectionIDFunction.self)
    )

    let getActiveSpace: CGSGetActiveSpaceFunction?
    let mainConnectionID: CGSConnectionIDFunction?
    let defaultConnection: CGSConnectionIDFunction?

    func connectionID() -> CGSConnectionID? {
        if let connectionID = mainConnectionID?(), connectionID != 0 {
            return connectionID
        }
        if let connectionID = defaultConnection?(), connectionID != 0 {
            return connectionID
        }
        return nil
    }
}

private let coreGraphicsHandle = dlopen(
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    RTLD_LAZY
)
private let dynamicLoaderDefault = UnsafeMutableRawPointer(bitPattern: -2)

private func loadSymbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let symbol = loadRawSymbol(name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

private func loadRawSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    if let dynamicLoaderDefault, let symbol = dlsym(dynamicLoaderDefault, name) {
        return symbol
    }
    guard let coreGraphicsHandle else { return nil }
    return dlsym(coreGraphicsHandle, name)
}
