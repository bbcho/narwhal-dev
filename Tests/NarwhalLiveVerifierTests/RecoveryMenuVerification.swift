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
            toggleLaunchAtLogin: { retryCount += 10 },
            checkForUpdates: { retryCount += 100 },
            copyDiagnostics: {},
            resetLayout: {},
            quit: {}
        ))
        defer { menubar.stop() }

        menubar.updateConfigStatus(.failed("invalid Lua near line 4"))
        menubar.updateRuntimeReadiness(.degraded(.serviceStartupFailed(service: "hotkeys")))
        menubar.updateLoginItemStatus(.enabled)
        guard let updateURL = URL(string: "https://github.com/bbcho/narwhal-dev/releases/tag/v2.0.0"),
              let updateVersion = try? SemanticVersion("2.0.0")
        else {
            return (false, "update verifier fixture was invalid")
        }
        menubar.updateUpdateStatus(.available(version: updateVersion, pageURL: updateURL))

        let expectedItems = [
            "Config: failed - invalid Lua near line 4",
            "Runtime: degraded - hotkeys failed to start",
            "Retry Startup",
            "Reload Config",
            "Open Config",
            "Accessibility Settings",
            "Reveal Logs",
            "Launch at Login",
            "Get Narwhal 2.0.0…",
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
        guard menubar.debugMenuItemIsOn(titled: "Launch at Login") == true,
              menubar.debugPerformMenuItem(titled: "Launch at Login"),
              retryCount == 11
        else {
            return (false, "Launch at Login was not rendered as a checked actionable menu item")
        }
        guard menubar.debugPerformMenuItem(titled: "Get Narwhal 2.0.0…"), retryCount == 111 else {
            return (false, "available update menu item did not invoke its action")
        }
        menubar.updateUpdateStatus(.checking)
        guard menubar.debugMenuItem(titled: "Checking for Updates…")?.isEnabled == false else {
            return (false, "in-progress update menu item remained enabled")
        }

        menubar.updateRuntimeReadiness(.operational)
        guard menubar.debugMenuItem(titled: "Retry Startup")?.isEnabled == false else {
            return (false, "Retry Startup remained enabled for an operational runtime")
        }

        return (true, "AppKit status menu exposed degraded state and recovery actions")
    }
}
#endif
