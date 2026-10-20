import Carbon
import Foundation
import NarwhalAppSupport
import NarwhalCore

@MainActor
final class HotkeyManager {
    private var bindings: [HotkeyBinding]
    private let reporter: StartupReporter
    private let fire: @Sendable (HotkeyAction) -> Void
    private var handlerRef: EventHandlerRef?
    private var hotkeyRefs: [EventHotKeyRef?] = []
    private var actionsByID: [UInt32: HotkeyAction] = [:]
    private var isStarted = false

    init(
        bindings: [HotkeyBinding] = Config.default.keymap,
        reporter: StartupReporter,
        fire: @escaping @Sendable (HotkeyAction) -> Void
    ) {
        self.bindings = bindings
        self.reporter = reporter
        self.fire = fire
    }

    /// Registers every binding it can. A binding another app already owns is
    /// reported and skipped rather than failing the whole service.
    @discardableResult
    func start() throws -> [HotkeyError] {
        guard !isStarted else { return [] }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleHotkeyEvent,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else {
            throw HotkeyError.installFailed(installStatus)
        }

        let failures = registerHotkeys(bindings)
        isStarted = true
        reporter.info("Registered hotkeys: \(bindings.map(describe).joined(separator: ", "))")
        return failures
    }

    func rebind(_ newBindings: [HotkeyBinding]) -> [HotkeyError] {
        unregisterHotkeys()
        let failures = registerHotkeys(newBindings)
        bindings = newBindings
        reporter.info("Rebound hotkeys: \(newBindings.map(describe).joined(separator: ", "))")
        return failures
    }

    func stop() {
        unregisterHotkeys()

        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        isStarted = false
    }

    private func registerHotkeys(_ bindings: [HotkeyBinding]) -> [HotkeyError] {
        let layoutKeyCodes = activeLayoutCharacterKeyCodes()
        var registeredRefs: [EventHotKeyRef?] = []
        var registered: [HotkeyRegistration] = []
        var failures: [HotkeyError] = []
        for registration in hotkeyRegistrations(for: bindings) {
            switch register(binding: registration.binding, id: registration.id, layoutKeyCodes: layoutKeyCodes) {
            case .success(let ref):
                registeredRefs.append(ref)
                registered.append(registration)
            case .failure(let error):
                reporter.error(error.description)
                failures.append(error)
            }
        }
        hotkeyRefs = registeredRefs
        actionsByID = hotkeyActionRegistry(for: registered)
        return failures
    }

    private func unregisterHotkeys() {
        unregister(refs: hotkeyRefs)
        hotkeyRefs.removeAll()
        actionsByID.removeAll()
    }

    private func register(
        binding: HotkeyBinding,
        id: UInt32,
        layoutKeyCodes: [String: UInt32]
    ) -> Result<EventHotKeyRef?, HotkeyError> {
        guard let keyCode = hotkeyKeyCode(for: binding.key.key, layoutKeyCodes: layoutKeyCodes) else {
            return .failure(.unsupportedKey(binding.key))
        }

        let hotkeyID = EventHotKeyID(signature: fourCharacterCode("WMGR"), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers(for: binding.key.modifiers),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else {
            return .failure(.registrationFailed(binding, status))
        }
        return .success(ref)
    }

    private func unregister(refs: [EventHotKeyRef?]) {
        for ref in refs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
    }

    private func fire(id: UInt32) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let action = actionsByID[id] else {
            reporter.error("Unknown hotkey id \(id)")
            return
        }
        fire(action)
    }

    // Safe iff Carbon dispatches on main; GetApplicationEventTarget() guarantees this.
    private static let handleHotkeyEvent: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )
        guard status == noErr else { return status }

        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated {
            manager.fire(id: hotkeyID.id)
        }
        return noErr
    }
}

enum HotkeyError: Error, CustomStringConvertible {
    case installFailed(OSStatus)
    case unsupportedKey(KeySpec)
    case registrationFailed(HotkeyBinding, OSStatus)

    var description: String {
        switch self {
        case .installFailed(let status):
            return "Carbon event handler install failed with \(status)"
        case .unsupportedKey(let key):
            return "Unsupported Carbon hotkey \(describe(key))"
        case .registrationFailed(let binding, let status):
            return "Carbon hotkey registration failed for \(describe(binding.key)) with \(status)"
        }
    }
}

/// The Carbon virtual key code for a validated hotkey key name. Character keys
/// prefer the active layout so "a" is the key that types "a" on AZERTY or
/// Dvorak; their US physical position is the fallback.
func hotkeyKeyCode(for key: String, layoutKeyCodes: [String: UInt32]) -> UInt32? {
    layoutKeyCodes[key] ?? usHotkeyKeyCodes[key]
}

private let usHotkeyKeyCodes: [String: UInt32] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
    "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
    "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
    "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
    "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
    "z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
    "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
    "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
    "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
    "`": kVK_ANSI_Grave,
    "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete,
    "forwarddelete": kVK_ForwardDelete, "escape": kVK_Escape,
    "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
    "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
    "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12
].mapValues { UInt32($0) }

/// Which key code types each hotkey character in the active keyboard layout.
/// Empty when the layout exposes no Unicode key data.
func activeLayoutCharacterKeyCodes() -> [String: UInt32] {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else {
        return [:]
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
    let characters = Set(HotkeyKeyNames.characters)
    return layoutData.withUnsafeBytes { buffer -> [String: UInt32] in
        guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
            return [:]
        }
        // Ascending key codes reach the main-row digits before the keypad digits,
        // so the first key code found for a character wins.
        return (UInt16(0)..<128).reduce(into: [String: UInt32]()) { result, keyCode in
            var deadKeyState: UInt32 = 0
            var length = 0
            var units = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                units.count,
                &length,
                &units
            )
            guard status == noErr, length == 1 else { return }
            let character = String(utf16CodeUnits: units, count: length).lowercased()
            if characters.contains(character), result[character] == nil {
                result[character] = UInt32(keyCode)
            }
        }
    }
}

private func carbonModifiers(for modifiers: ModifierSet) -> UInt32 {
    var result: UInt32 = 0
    if modifiers.contains(.control) {
        result |= UInt32(controlKey)
    }
    if modifiers.contains(.option) {
        result |= UInt32(optionKey)
    }
    if modifiers.contains(.shift) {
        result |= UInt32(shiftKey)
    }
    if modifiers.contains(.command) {
        result |= UInt32(cmdKey)
    }
    return result
}

private func describe(_ binding: HotkeyBinding) -> String {
    "\(describe(binding.key)) -> \(AppDelegateText.describe(binding.action))"
}

private func describe(_ key: KeySpec) -> String {
    (modifierNames(key.modifiers) + [key.key.uppercased()]).joined(separator: "-")
}

/// Modifier names in display order, for log text.
func modifierNames(_ modifiers: ModifierSet) -> [String] {
    [
        modifiers.contains(.control) ? "control" : nil,
        modifiers.contains(.option) ? "option" : nil,
        modifiers.contains(.shift) ? "shift" : nil,
        modifiers.contains(.command) ? "command" : nil
    ].compactMap { $0 }
}

private func fourCharacterCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { partial, byte in
        (partial << 8) + OSType(byte)
    }
}
