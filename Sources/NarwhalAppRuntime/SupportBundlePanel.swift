import AppKit
import UniformTypeIdentifiers

@MainActor
func supportBundleSavePanel(now: Date = Date()) -> NSSavePanel {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"

    let panel = NSSavePanel()
    panel.title = "Export Narwhal Support Bundle"
    panel.prompt = "Export"
    panel.nameFieldStringValue = "Narwhal-Support-\(formatter.string(from: now)).zip"
    panel.allowedContentTypes = [.zip]
    panel.allowsOtherFileTypes = false
    panel.isExtensionHidden = false
    panel.canCreateDirectories = true
    return panel
}
