import Carbon
import Foundation
import WinMgrCore

final class HotkeyManager {
    private let bindings: [HotkeyBinding]
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

    deinit {
        stop()
    }

    func start() throws {
        guard !isStarted else { return }

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

        do {
            for (offset, binding) in bindings.enumerated() {
                try register(binding: binding, id: UInt32(offset + 1))
            }
        } catch {
            stop()
            throw error
        }

        isStarted = true
        reporter.info("Registered hotkeys: \(bindings.map(describe).joined(separator: ", "))")
    }

    func stop() {
        for ref in hotkeyRefs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotkeyRefs.removeAll()
        actionsByID.removeAll()

        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        isStarted = false
    }

    private func register(binding: HotkeyBinding, id: UInt32) throws {
        guard let keyCode = carbonKeyCode(for: binding.key.key) else {
            throw HotkeyError.unsupportedKey(binding.key)
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
            throw HotkeyError.registrationFailed(binding, status)
        }
        hotkeyRefs.append(ref)
        actionsByID[id] = binding.action
    }

    private func fire(id: UInt32) {
        guard let action = actionsByID[id] else {
            reporter.error("Unknown hotkey id \(id)")
            return
        }
        fire(action)
    }

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
        manager.fire(id: hotkeyID.id)
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

private func carbonKeyCode(for key: String) -> UInt32? {
    switch key.lowercased() {
    case "h":
        return UInt32(kVK_ANSI_H)
    case "j":
        return UInt32(kVK_ANSI_J)
    case "k":
        return UInt32(kVK_ANSI_K)
    case "l":
        return UInt32(kVK_ANSI_L)
    case "r":
        return UInt32(kVK_ANSI_R)
    case "return":
        return UInt32(kVK_Return)
    case "space":
        return UInt32(kVK_Space)
    case "delete":
        return UInt32(kVK_Delete)
    default:
        return nil
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
    "\(describe(binding.key)) -> \(describe(binding.action))"
}

private func describe(_ key: KeySpec) -> String {
    let modifiers = [
        key.modifiers.contains(.control) ? "control" : nil,
        key.modifiers.contains(.option) ? "option" : nil,
        key.modifiers.contains(.shift) ? "shift" : nil,
        key.modifiers.contains(.command) ? "command" : nil
    ].compactMap { $0 }
    return (modifiers + [key.key.uppercased()]).joined(separator: "-")
}

private func describe(_ action: HotkeyAction) -> String {
    switch action {
    case .command(let template):
        return describe(template)
    case .reloadConfig:
        return "reloadConfig"
    }
}

private func describe(_ template: CommandTemplate) -> String {
    switch template {
    case .push(let direction):
        return "push \(direction.rawValue)"
    case .center:
        return "center"
    case .eject:
        return "eject"
    case .focusDirection(let direction):
        return "focus \(direction.rawValue)"
    case .toggleFloat:
        return "toggleFloat"
    case .resetLayout:
        return "resetLayout"
    }
}

private func fourCharacterCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { partial, byte in
        (partial << 8) + OSType(byte)
    }
}
