#if NARWHAL_ENABLE_VERIFIERS
import Foundation

@MainActor
func settleLiveVerifier(for interval: TimeInterval) async {
    serviceLiveVerifierRunLoop(for: interval)
}

@MainActor
private func serviceLiveVerifierRunLoop(for interval: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(max(0, interval)))
}
#endif
