#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import CoreGraphics
import Foundation
import NarwhalCore
import Testing

@MainActor
@Suite(
    "Real app window verifiers",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["NARWHAL_RUN_REAL_APP_VERIFIERS"] == "1",
        "Set NARWHAL_RUN_REAL_APP_VERIFIERS=1 to move and restore real app windows."
    )
)
struct RealAppWindowVerificationTests {
    @Test("Firefox accepts real AX frame writes")
    func firefoxAcceptsRealAXFrameWrites() throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(RealAppWindowVerification.verifyFirefox())
    }

    @Test("Chrome accepts real AX frame writes")
    func chromeAcceptsRealAXFrameWrites() throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(RealAppWindowVerification.verifyChrome())
    }

    @Test("System Settings accepts real AX frame writes")
    func systemSettingsAcceptsRealAXFrameWrites() throws {
        _ = NSApplication.shared
        VerifierAppDelegate.installIfNeeded()
        try expectPassed(RealAppWindowVerification.verifySystemSettings())
    }

    private func expectPassed(_ result: (passed: Bool, message: String)) throws {
        guard result.passed else {
            throw RealAppWindowVerifierFailure(result.message)
        }
    }
}

@MainActor
enum RealAppWindowVerification {
    static func verifyFirefox() -> (passed: Bool, message: String) {
        verifyApp(RealAppSpec(
            name: "Firefox",
            bundleIDs: ["org.mozilla.firefox"],
            launchName: "Firefox",
            launchExecutablePath: "/Applications/Firefox.app/Contents/MacOS/firefox",
            launchArguments: ["--new-window", "https://example.com/?narwhal-real-app=firefox"],
            minimumWindowSize: CGSize(width: 300, height: 120)
        ))
    }

    static func verifyChrome() -> (passed: Bool, message: String) {
        verifyApp(RealAppSpec(
            name: "Google Chrome",
            bundleIDs: ["com.google.Chrome"],
            launchName: "Google Chrome",
            launchExecutablePath: nil,
            launchArguments: ["https://example.com/?narwhal-real-app=chrome"],
            minimumWindowSize: CGSize(width: 420, height: 320)
        ))
    }

    static func verifySystemSettings() -> (passed: Bool, message: String) {
        verifyApp(RealAppSpec(
            name: "System Settings",
            bundleIDs: ["com.apple.SystemSettings", "com.apple.systempreferences"],
            launchName: "System Settings",
            launchExecutablePath: nil,
            launchArguments: [],
            minimumWindowSize: CGSize(width: 420, height: 320)
        ))
    }

    private static func verifyApp(_ spec: RealAppSpec) -> (passed: Bool, message: String) {
        do {
            try waitForUnlockedSession()
            let displays = DisplayClient().currentDisplays()
            guard !displays.isEmpty else {
                throw RealAppWindowVerifierFailure("no displays available")
            }
            guard displays.values.contains(where: { $0.visibleFrame.width >= 900 && $0.visibleFrame.height >= 620 }) else {
                throw RealAppWindowVerifierFailure("real app verification requires a display at least 900x620")
            }

            return (true, "real app frame verification passed: \(try verify(spec: spec, displays: displays))")
        } catch let error as RealAppWindowVerifierFailure {
            return (false, error.message)
        } catch {
            return (false, "real app verification failed: \(String(describing: error))")
        }
    }

    private static func waitForUnlockedSession() throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !isSystemLocked() {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        throw RealAppWindowVerifierFailure("real app verification requires an unlocked user session")
    }

    private static func verify(
        spec: RealAppSpec,
        displays: [DisplayID: DisplayInfo]
    ) throws -> String {
        let bundleID = try installedBundleID(for: spec)
        try launch(spec: spec, bundleID: bundleID)

        let axClient = AXClient(processID: -1)
        let original = try waitForUsableWindow(spec: spec, bundleID: bundleID, using: axClient)
        let restoreFrame = original.frame
        var didRestore = false
        defer {
            if !didRestore {
                do {
                    try restoreWindow(original, bundleID: bundleID, appName: spec.name, to: restoreFrame, using: axClient)
                } catch {
                    print("REAL APP VERIFY: failed to restore \(spec.name) window \(original.id.description): \(String(describing: error))")
                }
            }
        }

        switch axClient.focusWindow(original) {
        case .success:
            break
        case .failure(let error):
            print("REAL APP VERIFY: \(spec.name) focus was unavailable before frame writes: \(error.description)")
        }

        let display = displayContaining(original.frame, displays: displays)
            ?? displays.values.sorted(by: { $0.slot < $1.slot }).first!
        let targets = try targetFrames(in: display.visibleFrame, originalFrame: original.frame, spec: spec)
        var actuals: [CGRect] = []

        for (index, target) in targets.enumerated() {
            let actual = try verifyFrameWrite(
                target,
                metadata: original,
                appName: spec.name,
                step: index + 1,
                using: axClient
            )
            actuals.append(actual)
            LiveWindowServerVerification.reviewPause(
                "\(spec.name) step \(index + 1) matched real app frame \(actual.debugDescription)"
            )
        }

        guard actuals.contains(where: { !$0.matches(restoreFrame, tolerance: 8) }) else {
            throw RealAppWindowVerifierFailure("\(spec.name) did not visibly move away from its original frame")
        }

        try restoreWindow(original, bundleID: bundleID, appName: spec.name, to: restoreFrame, using: axClient)
        didRestore = true

        return "\(spec.name)=\(actuals.map(\.shortDescription).joined(separator: ","))"
    }

    private static func installedBundleID(for spec: RealAppSpec) throws -> String {
        for bundleID in spec.bundleIDs {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
                return bundleID
            }
        }
        throw RealAppWindowVerifierFailure(
            "\(spec.name) is not installed; tried bundle IDs \(spec.bundleIDs.joined(separator: ", "))"
        )
    }

    private static func launch(spec: RealAppSpec, bundleID: String) throws {
        let process = Process()
        if let launchExecutablePath = spec.launchExecutablePath {
            process.executableURL = URL(fileURLWithPath: launchExecutablePath)
            process.arguments = spec.launchArguments
        } else {
            var arguments = ["-a", spec.launchName]
            arguments.append(contentsOf: spec.launchArguments)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RealAppWindowVerifierFailure(
                "\(spec.name) launch failed with status \(process.terminationStatus)"
            )
        }
    }

    private static func waitForUsableWindow(
        spec: RealAppSpec,
        bundleID: String,
        using axClient: AXClient
    ) throws -> WindowMetadata {
        let deadline = Date().addingTimeInterval(14)
        var lastCandidates: [WindowMetadata] = []
        var lastSeen: [WindowMetadata] = []
        while Date() < deadline {
            lastSeen = axClient.windowSnapshot().windows
                .filter {
                    $0.bundleID.raw == bundleID
                }
                .sorted { $0.frame.area > $1.frame.area }
            lastCandidates = lastSeen
                .filter {
                    $0.isResizable
                        && !$0.isMinimized
                        && $0.frame.width >= spec.minimumWindowSize.width
                        && $0.frame.height >= spec.minimumWindowSize.height
                }
                .sorted { $0.frame.area > $1.frame.area }
            if let candidate = lastCandidates.first {
                return candidate
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        let seen = lastCandidates
            .map { "\($0.id.description) \($0.frame.shortDescription) resizable=\($0.isResizable)" }
            .joined(separator: ", ")
        let allSeen = lastSeen
            .map { "\($0.id.description) \($0.frame.shortDescription) resizable=\($0.isResizable) minimized=\($0.isMinimized) title=\"\($0.title)\"" }
            .joined(separator: ", ")
        throw RealAppWindowVerifierFailure(
            "\(spec.name) did not expose a usable resizable AX window for bundle \(bundleID) with minimum size \(spec.minimumWindowSize.shortDescription); candidates=[\(seen)] allVisibleForBundle=[\(allSeen)]"
        )
    }

    private static func verifyFrameWrite(
        _ target: CGRect,
        metadata: WindowMetadata,
        appName: String,
        step: Int,
        using axClient: AXClient
    ) throws -> CGRect {
        let actual: CGRect
        switch axClient.setFrame(metadata, to: target) {
        case .converged(let frame):
            actual = frame
        case .clamped(let frame, let observed):
            throw RealAppWindowVerifierFailure(
                "\(appName) step \(step) clamped instead of settling: target=\(target.debugDescription) actual=\(frame.debugDescription) observed=\(observed)"
            )
        case .failed(let error):
            throw RealAppWindowVerifierFailure(
                "\(appName) step \(step) frame write failed: \(error.description)"
            )
        }

        guard frameWriteApproximatelySettled(target: target, actual: actual, tolerance: 2) else {
            throw RealAppWindowVerifierFailure(
                "\(appName) step \(step) did not settle near target: target=\(target.debugDescription) actual=\(actual.debugDescription)"
            )
        }

        let serverFrame = LiveWindowServerVerification.waitForFrame(
            windowNumber: Int(metadata.id.raw),
            matching: actual,
            tolerance: 3
        )
        guard serverFrame?.matches(actual, tolerance: 3) == true else {
            throw RealAppWindowVerifierFailure(
                "\(appName) step \(step) WindowServer did not show actual frame: expected=\(actual.debugDescription) actual=\(serverFrame?.debugDescription ?? "nil")"
            )
        }

        return actual
    }

    private static func restoreWindow(
        _ original: WindowMetadata,
        bundleID: String,
        appName: String,
        to frame: CGRect,
        using axClient: AXClient
    ) throws {
        var failures: [String] = []
        switch axClient.setFrame(original, to: frame) {
        case .converged, .clamped:
            return
        case .failed(let error):
            failures.append("original=\(error.description)")
        }

        let candidates = axClient.windowSnapshot().windows
            .filter { $0.bundleID.raw == bundleID && $0.isResizable && !$0.isMinimized }
            .sorted {
                if $0.id == original.id { return true }
                if $1.id == original.id { return false }
                return $0.frame.area > $1.frame.area
            }
        for candidate in candidates {
            switch axClient.setFrame(candidate, to: frame) {
            case .converged, .clamped:
                return
            case .failed(let error):
                failures.append("\(candidate.id.description)=\(error.description)")
            }
        }

        throw RealAppWindowVerifierFailure(
            "\(appName) could not restore window to \(frame.debugDescription): \(failures.joined(separator: "; "))"
        )
    }

    private static func targetFrames(
        in visibleFrame: CGRect,
        originalFrame: CGRect,
        spec: RealAppSpec
    ) throws -> [CGRect] {
        let maxFirstWidth = visibleFrame.width - 96
        let maxSecondWidth = visibleFrame.width - 120
        let maxFirstHeight = visibleFrame.height - 96
        let maxSecondHeight = visibleFrame.height - 120
        let firstWidth: CGFloat
        let firstHeight: CGFloat
        let secondWidth: CGFloat
        let secondHeight: CGFloat
        switch spec.name {
        case "Firefox":
            firstWidth = min(originalFrame.width + 40, maxFirstWidth)
            firstHeight = min(originalFrame.height + 40, maxFirstHeight)
            secondWidth = min(originalFrame.width + 24, maxSecondWidth)
            secondHeight = min(originalFrame.height + 28, maxSecondHeight)
        case "System Settings":
            firstWidth = min(originalFrame.width + 32, maxFirstWidth)
            firstHeight = min(max(max(visibleFrame.height * 0.68, 560), originalFrame.height), maxFirstHeight)
            secondWidth = min(originalFrame.width + 16, maxSecondWidth)
            secondHeight = min(max(max(visibleFrame.height * 0.60, 520), originalFrame.height), maxSecondHeight)
        default:
            firstWidth = min(max(max(visibleFrame.width * 0.62, 760), originalFrame.width + 40), maxFirstWidth)
            firstHeight = min(max(max(visibleFrame.height * 0.68, 560), originalFrame.height + 240), maxFirstHeight)
            secondWidth = min(max(max(visibleFrame.width * 0.54, 760), originalFrame.width), maxSecondWidth)
            secondHeight = min(max(max(visibleFrame.height * 0.60, 520), originalFrame.height + 160), maxSecondHeight)
        }
        guard firstWidth > 0,
              firstHeight > 0,
              secondWidth > 0,
              secondHeight > 0,
              firstWidth >= originalFrame.width,
              secondWidth >= originalFrame.width
        else {
            throw RealAppWindowVerifierFailure(
                "\(spec.name) original window is too large for non-clamping real-app frame targets: original=\(originalFrame.debugDescription) visible=\(visibleFrame.debugDescription)"
            )
        }
        return [
            CGRect(
                x: visibleFrame.minX + 40,
                y: visibleFrame.minY + 44,
                width: firstWidth,
                height: firstHeight
            ).standardized,
            CGRect(
                x: visibleFrame.maxX - secondWidth - 56,
                y: visibleFrame.minY + 86,
                width: secondWidth,
                height: secondHeight
            ).standardized
        ]
    }

    private static func displayContaining(
        _ frame: CGRect,
        displays: [DisplayID: DisplayInfo]
    ) -> DisplayInfo? {
        if let byIntersection = displays.values.max(by: {
            $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area
        }), byIntersection.visibleFrame.intersection(frame).area > 0 {
            return byIntersection
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.values.min {
            $0.visibleFrame.center.distanceSquared(to: center) < $1.visibleFrame.center.distanceSquared(to: center)
        }
    }
}

private struct RealAppSpec {
    let name: String
    let bundleIDs: [String]
    let launchName: String
    let launchExecutablePath: String?
    let launchArguments: [String]
    let minimumWindowSize: CGSize
}

private struct RealAppWindowVerifierFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = "real app window verification failed: \(message)"
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull && !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var shortDescription: String {
        "(\(Int(minX)),\(Int(minY)),\(Int(width)),\(Int(height)))"
    }

    func matches(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

private extension CGSize {
    var shortDescription: String {
        "(\(Int(width)),\(Int(height)))"
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
#endif
