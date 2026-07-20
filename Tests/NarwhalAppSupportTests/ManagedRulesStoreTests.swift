import Foundation
import NarwhalAppSupport
import NarwhalCore
import Testing

@Suite("Managed rules store")
struct ManagedRulesStoreTests {
    @Test("Store round-trips validated rules with private permissions")
    func roundTrip() throws {
        let context = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let rules = [sampleRule()]

        try context.store.save(rules)

        #expect(try context.store.load() == rules)
        let attributes = try FileManager.default.attributesOfItem(atPath: context.store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Malformed data is quarantined and never treated as an empty valid file")
    func malformedFileIsQuarantined() throws {
        let context = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: context.store.url)

        let outcome = try context.store.loadRecovering(quarantineID: "test")

        guard case .recoveredEmpty(let recovery) = outcome else {
            Issue.record("Expected corrupt-file recovery, got \(outcome)")
            return
        }
        #expect(recovery.quarantinedFilename == "managed-rules.json.corrupt-test")
        #expect(!FileManager.default.fileExists(atPath: context.store.url.path))
        #expect(FileManager.default.fileExists(
            atPath: context.directory.appendingPathComponent(recovery.quarantinedFilename).path
        ))
    }

    @Test("Unknown schema remains in place for a newer compatible application")
    func unknownSchemaIsPreserved() throws {
        let context = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(StoredManagedRules(schemaVersion: 999, rules: [sampleRule()]))
        try data.write(to: context.store.url)

        let outcome = try context.store.loadRecovering()

        guard case .incompatible(.unsupportedSchemaVersion(found: 999, supported: 1)) = outcome else {
            Issue.record("Expected incompatible schema, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: context.store.url.path))
    }

    @Test("Invalid rules are rejected before a file is written")
    func invalidRuleIsNotWritten() throws {
        let context = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let invalid = ManagedWindowRule(
            id: ManagedRuleID(rawValue: "invalid"),
            name: "Invalid",
            matcher: ManagedRuleMatcher(),
            policy: ManagedRulePolicy()
        )

        #expect(throws: ManagedRulesStoreError.self) {
            try context.store.save([invalid])
        }
        #expect(!FileManager.default.fileExists(atPath: context.store.url.path))
    }

    private func temporaryStore() throws -> (directory: URL, store: ManagedRulesStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-managed-rules-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("managed-rules.json")
        return (directory, ManagedRulesStore(url: url))
    }

    private func sampleRule() -> ManagedWindowRule {
        ManagedWindowRule(
            id: ManagedRuleID(rawValue: "editor"),
            name: "Editor windows",
            matcher: ManagedRuleMatcher(bundleID: "com.example.editor", role: "AXWindow"),
            policy: ManagedRulePolicy(
                placement: .displaySlot(1),
                excludeFromFocusCycle: true,
                minimumWidth: 640,
                minimumHeight: 400
            )
        )
    }
}
