import AppKit
import ApplicationServices

enum AXNotificationEvent: Equatable, Sendable {
    case applicationActivated
    case focusedWindowChanged
    case focusedWindowGeometryChanged
    case windowInventoryChanged
}

@MainActor
final class AXNotificationClient {
    private struct Registration {
        let element: AXUIElement
        let notification: String
    }

    private static let applicationNotifications = [
        kAXFocusedWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification
    ]
    private static let focusedWindowNotifications = [
        kAXMovedNotification,
        kAXResizedNotification
    ]
    private static let messagingTimeout: Float = 1.0

    private let reporter: StartupReporter
    private let emit: @MainActor (AXNotificationEvent) -> Void
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var focusedWindow: AXUIElement?
    private var applicationRegistrations: [Registration] = []
    private var focusedWindowRegistrations: [Registration] = []
    private var workspaceObserver: NSObjectProtocol?
    private(set) var isActive = false

    init(
        reporter: StartupReporter,
        emit: @escaping @MainActor (AXNotificationEvent) -> Void
    ) {
        self.reporter = reporter
        self.emit = emit
    }

    func start() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.bindFrontmostApplication()
                self?.emit(.applicationActivated)
            }
        }
        bindFrontmostApplication()
    }

    func stop() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        tearDownObserver()
    }

    private func bindFrontmostApplication() {
        guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            tearDownObserver()
            return
        }

        tearDownObserver()
        var createdObserver: AXObserver?
        let creationError = AXObserverCreate(
            processID,
            Self.observerCallback,
            &createdObserver
        )
        guard creationError == .success, let createdObserver else {
            reporter.error("AX notification observer unavailable for pid=\(processID): \(creationError)")
            return
        }

        let application = Self.bounded(AXUIElementCreateApplication(processID))
        observer = createdObserver
        self.application = application
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )

        applicationRegistrations = Self.applicationNotifications.compactMap { notification in
            register(notification, on: application, observer: createdObserver)
        }
        bindFocusedWindow()
        updateActiveState()
    }

    private func bindFocusedWindow() {
        removeFocusedWindowRegistrations()
        guard let application, let observer else {
            updateActiveState()
            return
        }

        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard error == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            updateActiveState()
            return
        }

        let window = Self.bounded(value as! AXUIElement)
        focusedWindow = window
        focusedWindowRegistrations = Self.focusedWindowNotifications.compactMap { notification in
            register(notification, on: window, observer: observer)
        }
        updateActiveState()
    }

    private func register(
        _ notification: String,
        on element: AXUIElement,
        observer: AXObserver
    ) -> Registration? {
        let error = AXObserverAddNotification(
            observer,
            element,
            notification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard error == .success || error == .notificationAlreadyRegistered else {
            reporter.info("AX notification \(notification) unavailable: \(error)")
            return nil
        }
        return Registration(element: element, notification: notification)
    }

    private func receive(notification: String) {
        switch notification {
        case kAXFocusedWindowChangedNotification:
            bindFocusedWindow()
            emit(.focusedWindowChanged)
        case kAXMovedNotification, kAXResizedNotification:
            emit(.focusedWindowGeometryChanged)
        case kAXWindowCreatedNotification,
             kAXWindowMovedNotification,
             kAXWindowResizedNotification:
            emit(.windowInventoryChanged)
        default:
            break
        }
    }

    private func removeFocusedWindowRegistrations() {
        guard let observer else {
            focusedWindowRegistrations.removeAll()
            focusedWindow = nil
            return
        }
        remove(focusedWindowRegistrations, from: observer)
        focusedWindowRegistrations.removeAll()
        focusedWindow = nil
    }

    private func tearDownObserver() {
        guard let observer else {
            application = nil
            focusedWindow = nil
            applicationRegistrations.removeAll()
            focusedWindowRegistrations.removeAll()
            isActive = false
            return
        }

        removeFocusedWindowRegistrations()
        remove(applicationRegistrations, from: observer)
        applicationRegistrations.removeAll()
        application = nil
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        self.observer = nil
        isActive = false
    }

    private func remove(_ registrations: [Registration], from observer: AXObserver) {
        for registration in registrations {
            _ = AXObserverRemoveNotification(
                observer,
                registration.element,
                registration.notification as CFString
            )
        }
    }

    private func updateActiveState() {
        isActive = !applicationRegistrations.isEmpty || !focusedWindowRegistrations.isEmpty
    }

    private static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    // The observer source is installed on the main run loop.
    private static let observerCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let client = Unmanaged<AXNotificationClient>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated {
            client.receive(notification: notification as String)
        }
    }
}
