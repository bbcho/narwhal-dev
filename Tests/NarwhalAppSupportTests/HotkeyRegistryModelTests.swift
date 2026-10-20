import Testing
import NarwhalCore
@testable import NarwhalAppSupport

@Suite("Hotkey registry model")
struct HotkeyRegistryModelTests {
    @Test("Hotkey registrations assign stable one-based IDs")
    func hotkeyRegistrationsAssignStableOneBasedIDs() {
        let first = HotkeyBinding(
            key: KeySpec(key: "h", modifiers: [.control, .option]),
            action: .command(.focusDirection(.left))
        )
        let second = HotkeyBinding(
            key: KeySpec(key: "l", modifiers: [.control, .option, .command]),
            action: .command(.push(.right))
        )

        let registrations = hotkeyRegistrations(for: [first, second])

        #expect(registrations == [
            HotkeyRegistration(id: 1, binding: first),
            HotkeyRegistration(id: 2, binding: second)
        ])
    }

    @Test("Hotkey action registry maps each registration ID to its action")
    func hotkeyActionRegistryMapsEachRegistrationID() {
        let finder = HotkeyBinding(
            key: KeySpec(key: "f", modifiers: [.control, .option, .command]),
            action: .openFinderWindow
        )
        let reload = HotkeyBinding(
            key: KeySpec(key: "r", modifiers: [.control, .option, .command]),
            action: .reloadConfig
        )
        let registry = hotkeyActionRegistry(for: hotkeyRegistrations(for: [finder, reload]))

        #expect(registry == [1: .openFinderWindow, 2: .reloadConfig])
    }

    @Test("Empty hotkey registrations produce an empty action registry")
    func emptyHotkeyRegistrationsProduceEmptyActionRegistry() {
        let registrations = hotkeyRegistrations(for: [])

        #expect(registrations == [])
        #expect(hotkeyActionRegistry(for: registrations) == [:])
    }
}
