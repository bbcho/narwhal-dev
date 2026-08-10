import Foundation
import Testing

@Suite("Layout transaction routing")
struct LayoutTransactionRoutingTests {
    @Test("AppDelegate has one transaction execution path and no direct frame-apply bypass")
    func appDelegateUsesOnlyTheTransactionCoordinator() throws {
        let source = try appDelegateSource()

        #expect(source.occurrences(of: "layoutTransactionCoordinator.execute(") == 1)
        #expect(!source.contains("LayoutApplier("))
        #expect(!source.contains("plannedLayoutApplyDecision("))
        #expect(!source.contains("worldActor.commit("))
    }

    private func appDelegateSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("NarwhalAppRuntime")
                .appendingPathComponent("App.swift"),
            encoding: .utf8
        )
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
