import NarwhalAppSupport
import ServiceManagement

@MainActor
final class LoginItemController {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func performAction() throws -> LoginItemStatus {
        let service = SMAppService.mainApp
        switch service.status {
        case .notRegistered:
            try service.register()
        case .enabled:
            try service.unregister()
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
        return status
    }

    func unregister() throws {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            try SMAppService.mainApp.unregister()
        case .notRegistered, .notFound:
            return
        @unknown default:
            return
        }
    }
}
