import AppKit
import Foundation
import NarwhalCore

enum RuntimeDiagnosticsPresentationError: Error, Equatable {
    case pasteboardWriteFailed
}

func encodedRuntimeDiagnostics(_ diagnostics: RuntimeDiagnostics) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(diagnostics), as: UTF8.self)
}

@MainActor
func copyRuntimeDiagnostics(
    _ diagnostics: RuntimeDiagnostics,
    to pasteboard: NSPasteboard = .general
) throws {
    let encoded = try encodedRuntimeDiagnostics(diagnostics)
    pasteboard.clearContents()
    guard pasteboard.setString(encoded, forType: .string) else {
        throw RuntimeDiagnosticsPresentationError.pasteboardWriteFailed
    }
}
