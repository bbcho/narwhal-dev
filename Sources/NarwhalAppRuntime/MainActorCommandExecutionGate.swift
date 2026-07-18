@MainActor
final class MainActorCommandExecutionGate {
    private var isExecuting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<Value>(_ operation: @MainActor () async -> Value) async -> Value {
        await acquire()
        let value = await operation()
        release()
        return value
    }

    private func acquire() async {
        guard isExecuting else {
            isExecuting = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isExecuting = false
            return
        }

        waiters.removeFirst().resume()
    }
}
