#if NARWHAL_ENABLE_VERIFIERS
@testable import NarwhalAppRuntime
import AppKit

@MainActor
enum MenubarIconVerification {
    static func verifyStatusItemUsesToolbarIcon() -> (passed: Bool, message: String) {
        let menubar = Menubar()
        menubar.start(reload: {}, reset: {}, quit: {})
        defer { menubar.stop() }

        guard let snapshot = menubar.debugStatusButtonSnapshot() else {
            return (false, "menubar status item did not create a button")
        }
        guard snapshot.hasImage else {
            return (false, "menubar status item has no image")
        }
        guard snapshot.imageName == NarwhalIconResources.statusItemImageName else {
            return (false, "menubar status item image is \(snapshot.imageName ?? "nil")")
        }
        guard snapshot.isTemplate else {
            return (false, "menubar status item image is not a template image")
        }
        guard snapshot.title.isEmpty, snapshot.imagePosition == NSControl.ImagePosition.imageOnly else {
            return (
                false,
                "menubar status item is not image-only: title=\(snapshot.title) imagePosition=\(snapshot.imagePosition.rawValue)"
            )
        }
        guard snapshot.imageSize.width > 0, snapshot.imageSize.height > 0 else {
            return (false, "menubar status item image has invalid size: \(snapshot.imageSize)")
        }

        return (
            true,
            "menubar status icon verified: image=\(snapshot.imageName ?? "nil") size=\(snapshot.imageSize.width)x\(snapshot.imageSize.height) template=\(snapshot.isTemplate)"
        )
    }
}
#endif
