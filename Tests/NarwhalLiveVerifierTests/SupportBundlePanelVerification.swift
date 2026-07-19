#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum SupportBundlePanelVerification {
    static func verifyConfiguration() -> (passed: Bool, message: String) {
        let panel = supportBundleSavePanel(now: Date(timeIntervalSince1970: 0))
        guard panel.title == "Export Narwhal Support Bundle",
              panel.prompt == "Export",
              panel.allowedContentTypes == [.zip],
              panel.allowsOtherFileTypes == false,
              panel.isExtensionHidden == false,
              panel.canCreateDirectories,
              panel.nameFieldStringValue.hasPrefix("Narwhal-Support-"),
              panel.nameFieldStringValue.hasSuffix(".zip")
        else {
            return (false, "support bundle save panel configuration was incomplete")
        }
        return (true, "AppKit save panel constrained support export to a named ZIP archive")
    }
}
#endif
