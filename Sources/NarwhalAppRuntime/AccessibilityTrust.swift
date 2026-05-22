import ApplicationServices

enum AccessibilityStatus: Equatable {
    case trusted
    case notTrusted(prompted: Bool)

    var isTrusted: Bool {
        self == .trusted
    }
}

enum AccessibilityTrust {
    static func current(prompt: Bool) -> AccessibilityStatus {
        let options: CFDictionary? = if prompt {
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        } else {
            nil
        }

        if AXIsProcessTrustedWithOptions(options) {
            return .trusted
        }

        return .notTrusted(prompted: prompt)
    }
}
