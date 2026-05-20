import NarwhalCore

public struct HotkeyRegistration: Equatable, Sendable {
    public let id: UInt32
    public let binding: HotkeyBinding

    public init(id: UInt32, binding: HotkeyBinding) {
        self.id = id
        self.binding = binding
    }
}

public func hotkeyRegistrations(for bindings: [HotkeyBinding]) -> [HotkeyRegistration] {
    bindings.enumerated().map { offset, binding in
        HotkeyRegistration(id: UInt32(offset + 1), binding: binding)
    }
}

public func hotkeyActionRegistry(
    for registrations: [HotkeyRegistration]
) -> [UInt32: HotkeyAction] {
    Dictionary(uniqueKeysWithValues: registrations.map { registration in
        (registration.id, registration.binding.action)
    })
}

public func hotkeyAction(
    for id: UInt32,
    in registry: [UInt32: HotkeyAction]
) -> HotkeyAction? {
    registry[id]
}
