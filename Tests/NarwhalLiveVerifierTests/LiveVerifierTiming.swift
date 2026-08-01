#if NARWHAL_ENABLE_VERIFIERS
import AppKit
import Foundation

@MainActor
func settleLiveVerifier(for interval: TimeInterval) async {
    serviceLiveVerifierRunLoop(for: interval)
}

@MainActor
private func serviceLiveVerifierRunLoop(for interval: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(max(0, interval)))
}

@MainActor
func activateLiveVerifierApplication() async {
    // A BackgroundOnly SwiftPM helper can exit cleanly when it orders AppKit windows.
    NSApp.setActivationPolicy(.accessory)
    VerifierAppDelegate.installIfNeeded()
    NSApp.finishLaunching()
    VerifierAppDelegate.retainProcessActivityIfNeeded()
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    await settleLiveVerifier(for: 0.12)
}
#endif
