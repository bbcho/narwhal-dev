import Darwin
import CoreGraphics
import Foundation
import NarwhalAppSupport
import NarwhalCore

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

        var windowSpace = activeTopology.windowSpace
        if let copySpacesForWindows = symbols.copySpacesForWindows {
            windowSpace.merge(windowSpaces(
                for: windows,
                displays: displays,
                activeSpaceByDisplay: activeTopology.activeSpaceByDisplay,
                connectionID: connectionID,
                copySpacesForWindows: copySpacesForWindows
            )) { _, live in live }
        }

        return SpaceTopology(
            activeSpaceByDisplay: activeTopology.activeSpaceByDisplay,
            windowSpace: windowSpace,
            quality: activeTopology.quality
        )
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

struct SpaceSymbols {
    static let live = SpaceSymbols(
        getActiveSpace: loadSymbol("CGSGetActiveSpace", as: CGSGetActiveSpaceFunction.self),
        copyManagedDisplaySpaces: loadSymbol("SLSCopyManagedDisplaySpaces", as: SLSCopyManagedDisplaySpacesFunction.self),
        copySpacesForWindows: loadSymbol("SLSCopySpacesForWindows", as: SLSCopySpacesForWindowsFunction.self)
            ?? loadSymbol("CGSCopySpacesForWindows", as: SLSCopySpacesForWindowsFunction.self),
        mainConnectionID: loadSymbol("CGSMainConnectionID", as: CGSConnectionIDFunction.self),
        defaultConnection: loadSymbol("_CGSDefaultConnection", as: CGSConnectionIDFunction.self)
    )

    let getActiveSpace: CGSGetActiveSpaceFunction?
    let copyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFunction?
    let copySpacesForWindows: SLSCopySpacesForWindowsFunction?
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
    windows.reduce(into: [:]) { result, metadata in
        let ids = [NSNumber(value: metadata.id.raw)]
        guard let rawSpaces = copySpacesForWindows(connectionID, 7, ids as CFArray)?.takeRetainedValue() else {
            return
        }
        let spaces = (rawSpaces as NSArray)
            .compactMap { ($0 as? NSNumber).map { SpaceID(raw: $0.uint64Value) } }
        if let selected = selectedWindowSpace(
            for: metadata,
            candidateSpaces: spaces,
            displays: displays,
            activeSpaceByDisplay: activeSpaceByDisplay
        ) {
            result[metadata.id] = selected
        }
    }
}
