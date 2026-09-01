import Darwin
import CoreGraphics
import Foundation
import NarwhalAppSupport
import NarwhalCore

enum SpaceClientError: Error, Equatable, CustomStringConvertible {
    case symbolUnavailable(String)
    case connectionUnavailable
    case activeSpaceUnavailable
    case displayIdentifierUnavailable(DisplayID)
    case switchActiveSpaceFailed(status: Int32)

    var description: String {
        switch self {
        case .symbolUnavailable(let symbol):
            return "private CoreGraphics symbol unavailable: \(symbol)"
        case .connectionUnavailable:
            return "CoreGraphics connection unavailable"
        case .activeSpaceUnavailable:
            return "CGSGetActiveSpace returned 0"
        case .displayIdentifierUnavailable(let displayID):
            return "display identifier unavailable for display \(displayID.raw)"
        case .switchActiveSpaceFailed(let status):
            return "SLSManagedDisplaySetCurrentSpace failed with status \(status)"
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

    func spaceTopology(displays: [DisplayID: DisplayInfo], windows: [WindowMetadata]) -> SpaceTopology {
        guard let connectionID = symbols.connectionID() else {
            return SpaceTopology.replicated(activeSpace: tryActiveSpaceID(), displays: displays)
        }

        let activeTopology = symbols.copyManagedDisplaySpaces
            .flatMap { copyManagedDisplaySpaces in
                copyManagedDisplaySpaces(connectionID)?.takeRetainedValue()
            }
            .flatMap { ManagedDisplaySpacesParser.parse($0, displays: displays) }
            ?? SpaceTopology.replicated(activeSpace: tryActiveSpaceID(), displays: displays)

        let liveWindowSpace = symbols.copySpacesForWindows.map { copySpacesForWindows in
            windowSpaces(
                for: windows,
                displays: displays,
                activeSpaceByDisplay: activeTopology.activeSpaceByDisplay,
                connectionID: connectionID,
                copySpacesForWindows: copySpacesForWindows
            )
        } ?? [:]

        return spaceTopologyByMergingWindowSpaces(activeTopology, windowSpaces: liveWindowSpace)
    }

    func managedDisplaySpaceRows(displays: [DisplayID: DisplayInfo]) -> [DisplayID: ManagedDisplaySpacesDisplayRow] {
        guard let connectionID = symbols.connectionID(),
              let copyManagedDisplaySpaces = symbols.copyManagedDisplaySpaces,
              let raw = copyManagedDisplaySpaces(connectionID)?.takeRetainedValue()
        else {
            return [:]
        }

        return managedDisplaySpaceRowsByDisplay(
            rows: ManagedDisplaySpacesParser.parseRows(raw),
            displays: displays
        )
    }

    func spaces(forWindow windowID: WindowID) -> Result<[SpaceID], SpaceClientError> {
        guard let copySpacesForWindows = symbols.copySpacesForWindows else {
            return .failure(.symbolUnavailable("SLSCopySpacesForWindows"))
        }
        guard let connectionID = symbols.connectionID() else {
            return .failure(.connectionUnavailable)
        }
        guard let raw = copySpacesForWindows(
            connectionID,
            7,
            [NSNumber(value: windowID.raw)] as CFArray
        )?.takeRetainedValue() else {
            return .success([])
        }

        let spaces = (raw as NSArray).compactMap {
            ($0 as? NSNumber).map { SpaceID(raw: $0.uint64Value) }
        }
        return .success(spaces)
    }

    func userSpaceIDs(in spaces: [SpaceID]) -> Result<[SpaceID], SpaceClientError> {
        guard let getSpaceType = symbols.getSpaceType else {
            return .failure(.symbolUnavailable("SLSSpaceGetType"))
        }
        guard let connectionID = symbols.connectionID() else {
            return .failure(.connectionUnavailable)
        }
        return .success(spaces.filter { getSpaceType(connectionID, $0.raw) == 0 })
    }

    func switchActiveSpace(display: DisplayInfo, to spaceID: SpaceID) -> Result<Void, SpaceClientError> {
        guard let setCurrentSpace = symbols.setCurrentSpace else {
            return .failure(.symbolUnavailable("SLSManagedDisplaySetCurrentSpace"))
        }
        guard let connectionID = symbols.connectionID() else {
            return .failure(.connectionUnavailable)
        }
        guard let fingerprint = display.fingerprint else {
            return .failure(.displayIdentifierUnavailable(display.id))
        }

        let status = setCurrentSpace(connectionID, fingerprint as CFString, spaceID.raw)
        guard status == 0 else {
            return .failure(.switchActiveSpaceFailed(status: status))
        }
        return .success(())
    }

    private func tryActiveSpaceID() -> SpaceID? {
        guard case .success(let spaceID) = activeSpaceID() else { return nil }
        return spaceID
    }
}

typealias CGSConnectionID = Int32
typealias CGSGetActiveSpaceFunction = @convention(c) (CGSConnectionID) -> UInt64
typealias CGSConnectionIDFunction = @convention(c) () -> CGSConnectionID
typealias SLSCopyManagedDisplaySpacesFunction = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
typealias SLSCopySpacesForWindowsFunction = @convention(c) (CGSConnectionID, Int, CFArray) -> Unmanaged<CFArray>?
typealias SLSManagedDisplaySetCurrentSpaceFunction = @convention(c) (CGSConnectionID, CFString, UInt64) -> Int32
typealias SLSSpaceGetTypeFunction = @convention(c) (CGSConnectionID, UInt64) -> Int32

struct SpaceSymbols {
    static let live = SpaceSymbols(
        getActiveSpace: loadSymbol("CGSGetActiveSpace", as: CGSGetActiveSpaceFunction.self),
        copyManagedDisplaySpaces: loadSymbol("SLSCopyManagedDisplaySpaces", as: SLSCopyManagedDisplaySpacesFunction.self),
        copySpacesForWindows: loadSymbol("SLSCopySpacesForWindows", as: SLSCopySpacesForWindowsFunction.self)
            ?? loadSymbol("CGSCopySpacesForWindows", as: SLSCopySpacesForWindowsFunction.self),
        setCurrentSpace: loadSymbol("SLSManagedDisplaySetCurrentSpace", as: SLSManagedDisplaySetCurrentSpaceFunction.self)
            ?? loadSymbol("CGSManagedDisplaySetCurrentSpace", as: SLSManagedDisplaySetCurrentSpaceFunction.self),
        getSpaceType: loadSymbol("SLSSpaceGetType", as: SLSSpaceGetTypeFunction.self)
            ?? loadSymbol("CGSSpaceGetType", as: SLSSpaceGetTypeFunction.self),
        mainConnectionID: loadSymbol("CGSMainConnectionID", as: CGSConnectionIDFunction.self),
        defaultConnection: loadSymbol("_CGSDefaultConnection", as: CGSConnectionIDFunction.self)
    )

    let getActiveSpace: CGSGetActiveSpaceFunction?
    let copyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFunction?
    let copySpacesForWindows: SLSCopySpacesForWindowsFunction?
    let setCurrentSpace: SLSManagedDisplaySetCurrentSpaceFunction?
    let getSpaceType: SLSSpaceGetTypeFunction?
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
private let skyLightHandle = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
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
    if let skyLightHandle, let symbol = dlsym(skyLightHandle, name) {
        return symbol
    }
    guard let coreGraphicsHandle else { return nil }
    return dlsym(coreGraphicsHandle, name)
}

private func windowSpaces(
    for windows: [WindowMetadata],
    displays: [DisplayID: DisplayInfo],
    activeSpaceByDisplay: [DisplayID: SpaceID],
    connectionID: CGSConnectionID,
    copySpacesForWindows: SLSCopySpacesForWindowsFunction
) -> [WindowID: SpaceID] {
    let candidates = windows.compactMap { metadata -> WindowSpaceCandidate? in
        let ids = [NSNumber(value: metadata.id.raw)]
        guard let rawSpaces = copySpacesForWindows(connectionID, 7, ids as CFArray)?.takeRetainedValue() else {
            return nil
        }
        let spaces = (rawSpaces as NSArray)
            .compactMap { ($0 as? NSNumber).map { SpaceID(raw: $0.uint64Value) } }
        return WindowSpaceCandidate(metadata: metadata, candidateSpaces: spaces)
    }
    return assignedWindowSpaces(
        from: candidates,
        displays: displays,
        activeSpaceByDisplay: activeSpaceByDisplay
    )
}
