import AppKit
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore
import NarwhalIPC

extension AppDelegate {
    func runPushOnceAndTerminate(_ direction: Direction) {
        guard loadStartupConfigOrTerminate() else { return }

        let status = reportAccessibilityStatus(prompt: false)
        guard status.isTrusted else {
            reporter.error("Push command skipped because Accessibility is not trusted")
            NSApplication.shared.terminate(nil)
            return
        }

        Task { @MainActor in
            await workspaceMutationGate.perform {
                let environment = await refreshEnvironmentLocked(reason: "one-shot push")
                guard environment.activeSpace != nil else {
                    reporter.error("Push \(direction.rawValue) skipped because active Space is unavailable")
                    NSApplication.shared.terminate(nil)
                    return
                }
                guard await loadRestoreState(using: environment.snapshot) else {
                    NSApplication.shared.terminate(nil)
                    return
                }
                await performPush(direction)
                await requestTermination()
            }
        }
    }

    func startServices() {
        guard !servicesStarted else { return }

        let steps: [ServiceStartStep]
        switch startupArguments.serviceStartSteps(serviceStartSteps()) {
        case .success(let value):
            steps = value
        case .failure(let error):
            reporter.error(error.description)
            reporter.info("Runtime service startup failed; recovery menu remains available")
            updateRuntimeReadiness(.degraded(.serviceStartupFailed(service: "startup request")))
            return
        }

        switch startServiceSequence(steps) {
        case .success(let services):
            runningServices = services
            servicesStarted = true
            reporter.info("Layout command loop ready")
            updateRuntimeReadiness(operationalReadiness)
        case .failure(let error):
            runningServices = nil
            servicesStarted = false
            reporter.error(error.description)
            reporter.info("Runtime service startup failed; recovery menu remains available")
            updateRuntimeReadiness(.degraded(.serviceStartupFailed(service: error.service)))
        }
    }

    private func serviceStartSteps() -> [ServiceStartStep] {
        [
            ServiceStartStep(name: "hotkeys") {
                try self.installHotkeys()
            },
            ServiceStartStep(name: "axObserver") {
                self.installAXObserver()
            },
            ServiceStartStep(name: "displayObserver") {
                self.installDisplayObserver()
            },
            ServiceStartStep(name: "configWatcher") {
                try self.installConfigFileWatcher()
            },
            ServiceStartStep(name: "ipcServer") {
                try self.installIPCServer()
            },
            ServiceStartStep(name: "dragZones") {
                try self.installEventTap()
            }
        ]
    }

    @MainActor
    private func installHotkeys() throws -> ServiceStop {
        let manager = HotkeyManager(bindings: config.keymap, reporter: reporter) { [weak self] action in
            Task { @MainActor in
                self?.enqueueHotkey(action)
            }
        }
        try manager.start()
        hotkeyManager = manager
        return { [weak self, manager] in
            manager.stop()
            if self?.hotkeyManager === manager {
                self?.hotkeyManager = nil
            }
        }
    }

    @MainActor
    private func installAXObserver() -> ServiceStop {
        guard axObserverService == nil else {
            return {}
        }
        let service = AXObserverService(
            axClient: axClient,
            echoSuppressor: echoSuppressor,
            reporter: reporter,
            activeSpaceByDisplay: { [weak self] windows in
                guard let self else { return [:] }
                let displays = self.displayClient.currentDisplays()
                return self.spaceClient
                    .spaceTopology(displays: displays, windows: windows)
                    .activeSpaceByDisplay
            },
            spaceChanged: { [weak self] in
                self?.activeSpaceChanged()
            },
            windowsVanished: { [weak self] windowIDs in
                Task { @MainActor in
                    await self?.handleVanishedWindows(windowIDs)
                }
            },
            reconcileFocusedWindow: { [weak self] snapshot in
                self?.overlay.reconcileFocusBorderAfterObservation(ifCurrent: snapshot.id)
            }
        ) { [weak self] event, snapshot in
            Task { @MainActor in
                await self?.handleAXEvent(event, snapshot: snapshot)
            }
        }
        service.start()
        axObserverService = service
        return { [weak self, service] in
            self?.cancelSpaceTransitionTimers()
            service.stop()
            if self?.axObserverService === service {
                self?.axObserverService = nil
            }
        }
    }

    @MainActor
    private func installDisplayObserver() -> ServiceStop {
        guard displayObserverService == nil else {
            return {}
        }
        let service = DisplayObserverService(reporter: reporter) { [weak self] in
            self?.setTiledBorders([])
            self?.cancelDisplaySettledRefreshTimer()
            self?.scheduleCoalescedEnvironmentRefresh(.displayChanged)
        }
        service.start()
        displayObserverService = service
        return { [weak self, service] in
            service.stop()
            if self?.displayObserverService === service {
                self?.displayObserverService = nil
            }
        }
    }

    @MainActor
    private func installConfigFileWatcher() throws -> ServiceStop {
        guard configFileWatcherService == nil else {
            return {}
        }
        switch startupArguments.startupConfigRequest {
        case .success(let request):
            let service = ConfigFileWatcherService(configURL: request.url, reporter: reporter) { [weak self] in
                Task { @MainActor in
                    await self?.reloadConfig(reason: "file watcher")
                }
            }
            service.start()
            configFileWatcherService = service
            return { [weak self, service] in
                service.stop()
                if self?.configFileWatcherService === service {
                    self?.configFileWatcherService = nil
                }
            }
        case .failure(let error):
            throw error
        }
    }

    @MainActor
    private func installIPCServer() throws -> ServiceStop {
        guard ipcServer == nil else {
            return {}
        }
        let socketPath = try IPCDefaults.socketPath()
        let server = IPCServer(
            socketPath: socketPath,
            handle: { [weak self] command in
                await self?.handleIPCCommand(command) ?? .error(
                    commandID: CommandID(raw: "app-unavailable"),
                    code: "app_unavailable",
                    message: "NarwhalApp is not available"
                )
            },
            log: { [weak self] message in
                Task { @MainActor in
                    self?.reporter.error(message)
                }
            }
        )
        try server.start()
        ipcServer = server
        reporter.info("IPC server ready at \(socketPath)")
        return { [weak self, server] in
            server.stop()
            if self?.ipcServer === server {
                self?.ipcServer = nil
            }
        }
    }

    @MainActor
    private func installEventTap() throws -> ServiceStop {
        guard eventTapClient == nil else {
            return {}
        }
        let client = EventTapClient(
            modifier: config.dragModifier,
            reporter: reporter,
            targetWindowMayRaise: { [weak self] in
                self?.overlay.targetWindowMayRaise()
            },
            dragBegan: { [weak self] in
                self?.recordDragStartWindow()
            },
            dragChanged: { [weak self] location in
                Task { @MainActor in
                    self?.previewDragDrop(at: location)
                }
            },
            dragEnded: { [weak self] in
                Task { @MainActor in
                    self?.overlay.hideDragPreview()
                }
            },
            drop: { [weak self] location in
                // Taken now, before a queued drop could see the next gesture's start.
                let start = self?.dragStartWindow
                self?.dragStartWindow = nil
                Task { @MainActor in
                    guard let self else { return }
                    await self.workspaceMutationGate.perform {
                        await self.performDragDrop(at: location, start: start)
                    }
                }
            }
        )
        try client.start()
        eventTapClient = client
        return { [weak self, client] in
            client.stop()
            if self?.eventTapClient === client {
                self?.eventTapClient = nil
            }
        }
    }

    @MainActor
    func loadRestoreState(using snapshot: EnvironmentSnapshot) async -> Bool {
        guard snapshot.axSnapshot.quality == .complete else {
            reporter.error("Restore skipped because environment snapshot is \(AppDelegateText.describe(snapshot.axSnapshot.quality))")
            return true
        }

        do {
            switch try await restorePersistence.loadRecovering() {
            case .missing:
                reporter.info("Restore state not found at \(restorePersistence.url.path)")
                return true
            case .loaded(let stored):
                let restoredCount = await worldActor.restore(stored, from: snapshot)
                reporter.info("Restore state loaded; restored tiled windows=\(restoredCount)")
                await updateTiledBordersFromWorld()
                return true
            case .recoveredFromBackup(let stored, let recovery):
                restoreWarning = .restoreRecovered(
                    quarantinedFilenames: recovery.quarantinedFilenames
                )
                let restoredCount = await worldActor.restore(stored, from: snapshot)
                reporter.error(
                    "Invalid restore state quarantined as \(recovery.quarantinedFilenames.joined(separator: ", ")); recovered from backup"
                )
                reporter.info("Restore backup loaded; restored tiled windows=\(restoredCount)")
                await updateTiledBordersFromWorld()
                return true
            case .recoveredEmpty(let recovery):
                restoreWarning = .restoreReset(
                    quarantinedFilenames: recovery.quarantinedFilenames
                )
                reporter.error(
                    "Invalid restore state quarantined as \(recovery.quarantinedFilenames.joined(separator: ", ")); starting with empty layout"
                )
                return true
            case .incompatible(let recovery):
                let schemaError = recovery.backupError ?? recovery.primaryError
                reporter.error("Restore state is from a newer Narwhal (\(schemaError.description)); starting with an empty layout and not saving over it")
                restoreWarning = .restoreIncompatible
                restoreSavingSuspended = true
                return true
            }
        } catch {
            reporter.error("Restore state could not be read (\(String(describing: error))); starting with an empty layout and not saving")
            restoreWarning = .restoreUnavailable
            restoreSavingSuspended = true
            return true
        }
    }

    @MainActor
    func applyStartupConvergeLocked() async {
        switch await worldActor.planCurrentLayout() {
        case .success(nil):
            reporter.info("Startup restore convergence skipped: no restored tiled windows")
        case .success(let result?):
            _ = await applyPlannedLayout(
                result,
                operation: "Startup restore convergence",
                persistReason: "startup",
                retryOnClamp: true,
                showFocusBorder: false
            ) {
                await self.currentLayoutRetryPlan()
            }
        case .failure(let error):
            reporter.error("Startup restore convergence rejected by core: \(error.message)")
        }
    }
}
