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
        first.write(Data("first\n".utf8))
        first.flush()
        #expect(first.isAvailable)
        let second = FileLogSink(path: paths.file.path)
        second.write(Data("second\n".utf8))
        second.flush()
        #expect(second.isAvailable)

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
        sink.write(Data("overwritten".utf8))
        sink.flush()

        #expect(!sink.isAvailable)
        #expect(try String(contentsOf: target, encoding: .utf8) == "sentinel")
    }

    @Test("Routine writes become durable on flush and oversized lines are dropped")
    func logSinkFlushesRoutineWritesAndBoundsAdmission() throws {
        let paths = temporaryLogPath()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let sink = FileLogSink(path: paths.file.path, maximumPendingBytes: 4)

        sink.write(Data("five!".utf8))
        sink.write(Data("ok\n".utf8))
        sink.flush()

        #expect(sink.droppedLineCount == 1)
        #expect(try String(contentsOf: paths.file, encoding: .utf8) == "ok\n")
    }

    @Test("Error writes synchronize without a separate flush")
    func errorWritesAreImmediatelyDurable() throws {
        let paths = temporaryLogPath()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let sink = FileLogSink(path: paths.file.path)

        sink.write(Data("error\n".utf8), synchronizing: true)

        #expect(try String(contentsOf: paths.file, encoding: .utf8) == "error\n")
    }

    @Test("Startup rotation retains three private archives in newest-first order")
    func logSinkRotatesAtStartup() throws {
        let paths = temporaryLogPath()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("current".utf8).write(to: paths.file)
        try Data("one".utf8).write(to: URL(fileURLWithPath: paths.file.path + ".1"))
        try Data("two".utf8).write(to: URL(fileURLWithPath: paths.file.path + ".2"))
        try Data("three".utf8).write(to: URL(fileURLWithPath: paths.file.path + ".3"))

        let sink = FileLogSink(
            path: paths.file.path,
            maximumFileBytes: 7,
            retainedGenerations: 3
        )
        sink.write(Data("new\n".utf8))
        sink.flush()

        #expect(try String(contentsOf: paths.file, encoding: .utf8) == "new\n")
        #expect(try String(contentsOfFile: paths.file.path + ".1", encoding: .utf8) == "current")
        #expect(try String(contentsOfFile: paths.file.path + ".2", encoding: .utf8) == "one")
        #expect(try String(contentsOfFile: paths.file.path + ".3", encoding: .utf8) == "two")
        for generation in 0...3 {
            let path = generation == 0 ? paths.file.path : paths.file.path + ".\(generation)"
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
        }
    }

    private func temporaryLogPath() -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("narwhal-log-tests-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("narwhal.log"))
    }
}
