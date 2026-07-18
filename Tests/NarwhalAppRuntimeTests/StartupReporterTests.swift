import Foundation
import Testing
@testable import NarwhalAppRuntime

@Suite("Startup reporter file sink")
struct StartupReporterTests {
    @Test("Default log is private user Library state")
    func defaultLogUsesUserLibrary() {
        let expectedRoot = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Narwhal", isDirectory: true)
            .standardizedFileURL.path

        #expect(StartupReporter.standardLogPath.hasPrefix(expectedRoot + "/"))
        #expect(!StartupReporter.standardLogPath.hasPrefix("/tmp/"))
        #expect(!StartupReporter.standardLogPath.hasPrefix("/private/tmp/"))
    }

    @Test("Log sink appends and enforces owner-only permissions")
    func logSinkAppendsWithPrivatePermissions() throws {
        let paths = temporaryLogPath()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let first = FileLogSink(path: paths.file.path)
        #expect(first.isAvailable)
        first.write(Data("first\n".utf8))
        let second = FileLogSink(path: paths.file.path)
        #expect(second.isAvailable)
        second.write(Data("second\n".utf8))

        #expect(try String(contentsOf: paths.file, encoding: .utf8) == "first\nsecond\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test("Log sink refuses a symbolic-link target")
    func logSinkRefusesSymbolicLinkTarget() throws {
        let paths = temporaryLogPath()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let target = paths.root.appendingPathComponent("target.txt")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: paths.file.path,
            withDestinationPath: target.path
        )

        let sink = FileLogSink(path: paths.file.path)
        #expect(!sink.isAvailable)
        sink.write(Data("overwritten".utf8))

        #expect(try String(contentsOf: target, encoding: .utf8) == "sentinel")
    }

    private func temporaryLogPath() -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-log-tests-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("narwhal.log"))
    }
}
