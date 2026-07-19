#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import NarwhalAppSupport

@MainActor
enum RecoveryMenuVerification {
    static func verifyDegradedRuntimeActions() -> (passed: Bool, message: String) {
        let menubar = Menubar()
        var retryCount = 0
        menubar.start(actions: MenubarActions(
            reloadConfig: {},
            retryStartup: { retryCount += 1 },
            openConfig: {},
            openAccessibilitySettings: {},
            revealLogs: {},
            copyDiagnostics: {},
            resetLayout: {},
            quit: {}
        ))
        defer { menubar.stop() }

        menubar.updateConfigStatus(.failed("invalid Lua near line 4"))
        menubar.updateRuntimeReadiness(.degraded(.serviceStartupFailed(service: "hotkeys")))

        let expectedItems = [
            "Config: failed - invalid Lua near line 4",
            "Runtime: degraded - hotkeys failed to start",
            "Retry Startup",
            "Reload Config",
            "Open Config",
            "Accessibility Settings",
            "Reveal Logs",
            "Copy Diagnostics",
            "Reset Layout",
            "Quit Narwhal"
        ]
        let titles = menubar.debugMenuTitles()
        guard expectedItems.allSatisfy(titles.contains) else {
            return (false, "recovery menu items did not match: \(titles)")
        }
        guard menubar.debugMenuItem(titled: "Retry Startup")?.isEnabled == true else {
            return (false, "Retry Startup was disabled for a degraded runtime")
        }
        guard menubar.debugPerformMenuItem(titled: "Retry Startup"), retryCount == 1 else {
            return (false, "Retry Startup did not invoke its action exactly once")
        }

        menubar.updateRuntimeReadiness(.operational)
        guard menubar.debugMenuItem(titled: "Retry Startup")?.isEnabled == false else {
            return (false, "Retry Startup remained enabled for an operational runtime")
        }

        return (true, "AppKit status menu exposed degraded state and recovery actions")
    }
}
#endif
