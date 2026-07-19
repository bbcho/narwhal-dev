import Foundation
import NarwhalAppSupport
import NarwhalCore

enum SupportBundleError: Error, CustomStringConvertible {
    case archiveFailed(Int32)

    var description: String {
        switch self {
        case .archiveFailed(let status):
            return "support bundle archive failed with status \(status)"
        }
    }
}

struct SupportBundleBuilder: Sendable {
    private static let retainedLogGenerations = 3
    private static let maximumLogBytes = 4 * 1_024 * 1_024

    let logURL: URL

    func write(diagnostics: RuntimeDiagnostics, to destination: URL) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("narwhal-support-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: staging) }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        let diagnosticsData = try diagnosticsJSON(diagnostics)
        try diagnosticsData.write(
            to: staging.appendingPathComponent("diagnostics.json"),
            options: .atomic
        )
        try redactedLogs().write(
            to: staging.appendingPathComponent("narwhal.log"),
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", staging.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0
        else {
            throw SupportBundleError.archiveFailed(process.terminationStatus)
        }
    }

    private func diagnosticsJSON(_ diagnostics: RuntimeDiagnostics) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(diagnostics)
    }

    private func redactedLogs() -> String {
        let generationURLs = stride(
            from: Self.retainedLogGenerations,
            through: 1,
            by: -1
        ).map {
            ("narwhal.log.\($0)", URL(fileURLWithPath: "\(logURL.path).\($0)"))
        } + [("narwhal.log", logURL)]

        var remainingBytes = Self.maximumLogBytes
        var sections: [String] = []
        for (name, url) in generationURLs.reversed() where remainingBytes > 0 {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  !data.isEmpty
            else { continue }
            var retained = Data(data.suffix(min(data.count, remainingBytes)))
            if retained.count < data.count,
               let newline = retained.firstIndex(of: 0x0A) {
                retained.removeSubrange(...newline)
            }
            remainingBytes -= retained.count
            let content = String(decoding: retained, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { redactedLogMessage(String($0)) }
                .joined(separator: "\n")
            sections.append("--- \(name) ---\n\(content)")
        }
        return sections.reversed().joined(separator: "\n")
    }
}
