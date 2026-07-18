#if NARWHAL_ENABLE_VERIFIERS
import Foundation

@MainActor
private final class LiveVerifierAsyncResult<Value> {
    var value: Value?
    var isComplete = false
}

/// Bridges production async APIs into legacy AppKit verifier helpers whose
/// surrounding workflow is intentionally driven by explicit run-loop polling.
@MainActor
func awaitLiveVerifierOperation<Value>(
    _ operation: @escaping @MainActor () async -> Value
) -> Value {
    let result = LiveVerifierAsyncResult<Value>()
    Task { @MainActor in
        result.value = await operation()
        result.isComplete = true
    }
    while !result.isComplete {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return result.value!
}
#endif
