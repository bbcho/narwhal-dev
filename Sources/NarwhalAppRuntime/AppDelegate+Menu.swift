import AppKit
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

extension AppDelegate {
    @MainActor
    func startMenubar() {
        menubar.start(actions: MenubarActions(
            openWorkbench: { [weak self] in
                self?.workbenchController.show()
            },
            reloadConfig: { [weak self] in
                Task { @MainActor in
                    await self?.reloadConfig(reason: "menubar")
                }
            },
            retryStartup: { [weak self] in
                self?.retryStartupFromMenu()
            },
            openConfig: { [weak self] in
                self?.openConfigFromMenu()
            },
            openAccessibilitySettings: { [weak self] in
                self?.openAccessibilitySettingsFromMenu()
            },
            revealLogs: { [weak self] in
                self?.revealLogsFromMenu()
            },
            toggleLaunchAtLogin: { [weak self] in
                self?.toggleLaunchAtLoginFromMenu()
            },
            checkForUpdates: { [weak self] in
                self?.handleUpdateMenuAction()
            },
            exportSupportBundle: { [weak self] in
                self?.exportSupportBundleFromMenu()
            },
            copyDiagnostics: { [weak self] in
                Task { @MainActor in
                    await self?.copyDiagnosticsToPasteboard()
                }
            },
            resetLayout: { [weak self] in
                Task { @MainActor in
                    self?.enqueueHotkey(.command(.resetLayout))
                }
            },
            quit: { [weak self] in
                Task { @MainActor in
                    await self?.requestTermination()
                }
            }
        ))
        if let startupConfigFailure {
            menubar.updateConfigStatus(.failed(startupConfigFailure.description))
        } else {
            menubar.updateConfigStatus(.loaded)
        }
        menubar.updateRuntimeReadiness(runtimeReadiness)
        menubar.updateLoginItemStatus(loginItemController.status)
        menubar.updateUpdateStatus(updateStatus)
        menubar.updateOperatingStatus(operatingStatus)
    }

    var operationalReadiness: RuntimeReadiness {
        if let restoreWarning {
            return .operationalWithWarning(restoreWarning)
        }
        if let configWarning {
            return .operationalWithWarning(configWarning)
        }
        return .operational
    }

    private func retryStartupFromMenu() {
        guard !servicesStarted, runtimeReadiness.canRetryStartup else { return }

        let status = reportAccessibilityStatus(prompt: true)
        guard status.isTrusted else {
            updateRuntimeReadiness(.waitingForAccessibility)
            return
        }

        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        updateRuntimeReadiness(.starting)
        Task { @MainActor in
            await startAfterAccessibilityTrusted()
        }
    }

    private func openConfigFromMenu() {
        let url: URL
        switch startupArguments.startupConfigRequest {
        case .success(let request):
            url = request.url
        case .failure:
            url = StartupConfigLoader.defaultUserConfigURL
        }

        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try DefaultConfigLua.render().write(to: url, atomically: true, encoding: .utf8)
                reporter.info("Created default user config")
            }
            guard NSWorkspace.shared.open(url) else {
                reporter.error("Open Config failed: workspace rejected the file")
                showOperatorFeedback("Could not open config", tone: .error)
                return
            }
        } catch {
            reporter.error("Open Config failed: \(String(describing: error))")
            showOperatorFeedback("Could not open config", tone: .error)
        }
    }

    func openAccessibilitySettingsFromMenu() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url)
        else {
            reporter.error("Accessibility Settings could not be opened")
            showOperatorFeedback("Could not open Accessibility Settings", tone: .error)
            return
        }
        reporter.info("Opened Accessibility Settings")
    }

    private func revealLogsFromMenu() {
        let logURL = URL(fileURLWithPath: StartupReporter.defaultLogPath)
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
        reporter.info("Revealed runtime log")
    }

    private func toggleLaunchAtLoginFromMenu() {
        do {
            let status = try loginItemController.performAction()
            menubar.updateLoginItemStatus(status)
            switch status {
            case .enabled:
                reporter.info("Launch at Login enabled")
            case .disabled:
                reporter.info("Launch at Login disabled")
            case .requiresApproval:
                reporter.info("Launch at Login requires approval in System Settings")
            case .unavailable:
                reporter.error("Launch at Login is unavailable for this app bundle")
            case .failed:
                break
            }
        } catch {
            let message = String(describing: error)
            menubar.updateLoginItemStatus(.failed(message))
            reporter.error("Launch at Login update failed: \(message)")
            showOperatorFeedback("Launch at Login update failed", tone: .error)
        }
    }

    private func handleUpdateMenuAction() {
        if case .available(_, let pageURL) = updateStatus {
            guard NSWorkspace.shared.open(pageURL) else {
                reporter.error("Available update page could not be opened")
                showOperatorFeedback("Could not open update page", tone: .error)
                return
            }
            reporter.info("Opened available update page")
            return
        }
        checkForUpdates()
    }

    private func checkForUpdates() {
        guard updateCheckTask == nil else { return }

        let currentVersion: SemanticVersion
        do {
            let value = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? ""
            currentVersion = try SemanticVersion(value)
        } catch {
            updateStatus = .failed
            menubar.updateUpdateStatus(updateStatus)
            reporter.error("Update check failed: current app version is invalid")
            showOperatorFeedback("Update check failed", tone: .error)
            return
        }

        updateStatus = .checking
        menubar.updateUpdateStatus(updateStatus)
        reporter.info("Checking for updates")
        updateCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let release = try await updateChecker.latestRelease()
                guard !Task.isCancelled else { return }
                switch updateAvailability(
                    current: currentVersion,
                    latest: release.version,
                    pageURL: release.pageURL
                ) {
                case .current:
                    updateStatus = .current
                    reporter.info("Narwhal is up to date")
                    showOperatorFeedback("Narwhal is up to date", tone: .success)
                case .newer(let version, let pageURL):
                    updateStatus = .available(version: version, pageURL: pageURL)
                    reporter.info("Narwhal update \(version.description) is available")
                    showOperatorFeedback("Narwhal \(version.description) is available", tone: .success)
                }
            } catch {
                guard !Task.isCancelled else { return }
                updateStatus = .failed
                reporter.error("Update check failed: \(String(describing: error))")
                showOperatorFeedback("Update check failed", tone: .error)
            }
            menubar.updateUpdateStatus(updateStatus)
            updateCheckTask = nil
        }
    }

    private func exportSupportBundleFromMenu() {
        let panel = supportBundleSavePanel()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK,
                  let destination = panel.url,
                  let self
            else { return }
            Task { @MainActor in
                let diagnostics = await self.runtimeDiagnostics()
                self.reporter.flush()
                let builder = SupportBundleBuilder(
                    logURL: URL(fileURLWithPath: StartupReporter.defaultLogPath)
                )
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        try builder.write(diagnostics: diagnostics, to: destination)
                    }
                }.value
                switch result {
                case .success:
                    self.reporter.info("Support bundle exported")
                    self.showOperatorFeedback("Support bundle exported", tone: .success)
                case .failure(let error):
                    self.reporter.error("Support bundle export failed: \(String(describing: error))")
                    self.showOperatorFeedback("Support bundle export failed", tone: .error)
                }
            }
        }
    }

    func runtimeDiagnostics() async -> RuntimeDiagnostics {
        let bundle = Bundle.main
        return RuntimeDiagnostics(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            accessibilityTrusted: operatingStatus.accessibilityTrusted == true,
            notificationFastPathActive: axObserverService?.notificationFastPathActive == true,
            configHealthy: configHealthy,
            paused: isPaused,
            activeSpaceID: operatingStatus.activeSpace?.raw,
            displayCount: operatingStatus.displayCount ?? 0,
            windowCount: operatingStatus.windowCount ?? 0,
            tiledWindowCount: await worldActor.tiledWindowCount(),
            snapshotQuality: runtimeSnapshotQuality(operatingStatus.snapshotQuality),
            focusedWindowID: operatingStatus.focusedWindowID?.raw,
            lastCommand: operatingStatus.lastCommand,
            pendingHotkeyCount: pendingHotkeys.count,
            pendingGeometryEventCount: externalGeometryCoordinator.pendingCount,
            droppedLogLineCount: reporter.droppedLogLineCount,
            latency: runtimeMetrics.summaries()
        )
    }

    @MainActor
    private func copyDiagnosticsToPasteboard() async {
        do {
            try copyRuntimeDiagnostics(await runtimeDiagnostics())
            reporter.info("Runtime diagnostics copied to pasteboard")
            showOperatorFeedback("Diagnostics copied", tone: .success)
        } catch {
            reporter.error("Runtime diagnostics copy failed: \(String(describing: error))")
            showOperatorFeedback("Diagnostics copy failed", tone: .error)
        }
    }
}
