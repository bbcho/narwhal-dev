import Foundation
import Testing

@Suite("Layout transaction routing")
struct LayoutTransactionRoutingTests {
    @Test("AppDelegate has one transaction execution path and no direct frame-apply bypass")
    func appDelegateUsesOnlyTheTransactionCoordinator() throws {
        let source = try appDelegateSource()

        #expect(source.occurrences(of: "layoutTransactionCoordinator.execute(") == 1)
        #expect(!source.contains("worldActor.commit("))
    }

    /// App.swift plus every `AppDelegate+*.swift` extension file.
    private func appDelegateSource() throws -> String {
        let runtimeSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("NarwhalAppRuntime")
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: runtimeSources.path)
            .filter { $0 == "App.swift" || $0.hasPrefix("AppDelegate+") }
            .sorted()
        return try fileNames
            .map { try String(contentsOf: runtimeSources.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
