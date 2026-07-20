import Foundation
import NarwhalAppSupport
import NarwhalCore
import Testing

@Suite("Named layouts store")
struct NamedLayoutsStoreTests {
    @Test("Store round-trips layouts and protects the file")
    func roundTrip() throws {
        let context = temporaryStore()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let layouts = [sampleLayout()]

        try context.store.save(layouts)

        #expect(try context.store.load() == layouts)
        let attributes = try FileManager.default.attributesOfItem(atPath: context.store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Malformed data is quarantined")
    func quarantine() throws {
        let context = temporaryStore()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: context.store.url)

        let outcome = try context.store.loadRecovering(quarantineID: "test")

        guard case .recoveredEmpty(let recovery) = outcome else {
            Issue.record("Expected corrupt-file recovery, got \(outcome)")
            return
        }
        #expect(recovery.quarantinedFilename == "layouts.json.corrupt-test")
        #expect(!FileManager.default.fileExists(atPath: context.store.url.path))
    }

    @Test("Duplicate IDs and malformed templates are rejected before writing")
    func validation() throws {
        let context = temporaryStore()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let layout = sampleLayout()

        #expect(throws: NamedLayoutsStoreError.self) {
            try context.store.save([layout, layout])
        }
        #expect(!FileManager.default.fileExists(atPath: context.store.url.path))
    }

    private func temporaryStore() -> (directory: URL, store: NamedLayoutsStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-layouts-\(UUID().uuidString)", isDirectory: true)
        return (
            directory,
            NamedLayoutsStore(url: directory.appendingPathComponent("layouts.json"))
        )
    }

    private func sampleLayout() -> NamedLayout {
        NamedLayout(
            id: NamedLayoutID(rawValue: "coding"),
            name: "Coding",
            displays: [DisplayLayoutTemplate(
                displaySlot: 0,
                root: .split(axis: .horizontal, cells: [
                    LayoutTemplateCell(
                        weight: 2,
                        node: .slot(LayoutTemplateSlot(
                            id: LayoutSlotID(rawValue: "editor"),
                            matcher: LayoutWindowMatcher(bundleID: "com.example.editor")
                        ))
                    ),
                    LayoutTemplateCell(
                        weight: 1,
                        node: .slot(LayoutTemplateSlot(
                            id: LayoutSlotID(rawValue: "docs"),
                            matcher: LayoutWindowMatcher(
                                bundleID: "com.example.browser",
                                role: "AXWindow",
                                title: .regex("Documentation")
                            )
                        ))
                    )
                ])
            )]
        )
    }
}
