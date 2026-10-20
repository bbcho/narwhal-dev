import AppKit
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

extension AppDelegate {
    @discardableResult
    func loadStartupConfigOrTerminate() -> Bool {
        let ok = loadStartupConfig()
        if !ok {
            NSApplication.shared.terminate(nil)
        }
        return ok
    }

    @discardableResult
    func configureRestoreManagerOrTerminate() -> Bool {
        switch startupArguments.restoreStateURL {
        case .success(let url):
            let manager = RestoreManager(url: url)
            restorePersistence = restorePersistence(for: manager)
            if url != RestoreManager.defaultURL {
                reporter.info("Using restore state path \(url.path)")
            }
            return true
        case .failure(let error):
            reporter.error(error.description)
            reporter.info("NarwhalApp stopped")
            exitAfterFlushing(1)
        }
    }

    func restorePersistence(for manager: RestoreManager) -> RestorePersistence {
        RestorePersistence(
            manager: manager,
            debounceInterval: Self.restoreSaveDebounceInterval,
            measureSave: { [runtimeMetrics] durationMilliseconds in
                runtimeMetrics.record(.restoreWrite, durationMilliseconds: durationMilliseconds)
            }
        ) { [reporter] event in
            logRestoreSaveEvent(event, reporter: reporter)
        }
    }

    @discardableResult
    func loadStartupConfig() -> Bool {
        switch startupConfigLoad() {
        case .success(let loaded):
            activateStartupConfig(configByRefreshingManagedRules(loaded.config))
            logStartupConfig(loaded)
            return true
        case .failure(let error):
            reporter.error("Startup config failed: \(error.description)")
            return false
        }
    }

    func loadNormalStartupConfig() {
        switch startupConfigLoad() {
        case .success(let loaded):
            activateStartupConfig(configByRefreshingManagedRules(loaded.config))
            configHealthy = true
            startupConfigFailure = nil
            configWarning = nil
            logStartupConfig(loaded)
        case .failure(let error):
            activateStartupConfig(configByRefreshingManagedRules(.default))
            configHealthy = false
            startupConfigFailure = error
            configWarning = .configFallback
            reporter.error("Startup config failed; using built-in defaults: \(error.description)")
        }
    }

    private func activateStartupConfig(_ activeConfig: Config) {
        config = activeConfig
        worldActor = WorldActor(config: activeConfig, runtimeMetrics: runtimeMetrics)
        overlay.updateConfig(border: activeConfig.border, hud: activeConfig.hud)
    }

    private func configByRefreshingManagedRules(_ baseConfig: Config) -> Config {
        do {
            switch try managedRulesStore.loadRecovering() {
            case .missing:
                managedRules = []
                managedRulesWarning = nil
            case .loaded(let loadedRules):
                managedRules = loadedRules
                managedRulesWarning = nil
                reporter.info("Loaded \(loadedRules.count) managed window rules")
            case .recoveredEmpty(let recovery):
                managedRulesWarning = recovery.error.description
                reporter.error(
                    "Managed rules were invalid; preserving \(managedRules.count) active rules and quarantined \(recovery.quarantinedFilename): \(recovery.error.description)"
                )
            case .incompatible(let error):
                managedRulesWarning = error.description
                reporter.error(
                    "Managed rules were written by an incompatible version; preserving \(managedRules.count) active rules: \(error.description)"
                )
            }
        } catch {
            managedRulesWarning = String(describing: error)
            reporter.error(
                "Managed rules could not be read; preserving \(managedRules.count) active rules: \(error)"
            )
        }
        return baseConfig.withManagedRules(managedRules)
    }

    private func startupConfigLoad() -> Result<StartupConfigLoad, StartupConfigError> {
        switch startupArguments.startupConfigRequest {
        case .success(let request):
            return StartupConfigLoader(configURL: request.url, missingFilePolicy: request.missingFilePolicy).load()
        case .failure(let error):
            return .failure(error)
        }
    }

    private func logStartupConfig(_ loaded: StartupConfigLoad) {
        switch loaded.source {
        case .builtInDefault(let missingUserConfig):
            reporter.info("Startup config not found at \(missingUserConfig.path); using built-in defaults")
        case .userFile(let url):
            reporter.info("Loaded startup config from \(url.path)")
        }
        reporter.info(
            "Startup config active: \(config.keymap.count) hotkeys, \(config.zones.count) zones, \(config.managedRules.count) managed rules"
        )
    }

    @MainActor
    func reloadConfig(reason: String) async {
        await workspaceMutationGate.perform {
            await self.reloadConfigLocked(reason: reason)
        }
    }

    @MainActor
    func reloadConfigLocked(reason: String) async {
        let loaded: StartupConfigLoad
        switch await backgroundStartupConfigLoad() {
        case .success(let value):
            loaded = value
        case .failure(let error):
            reporter.error("Config reload failed (\(reason)): \(error.description)")
            configHealthy = false
            configWarning = .configReloadFailed
            menubar.updateConfigStatus(.failed(error.description))
            if servicesStarted {
                updateRuntimeReadiness(operationalReadiness)
            }
            showOperatorFeedback("Config reload failed", tone: .error)
            return
        }

        let hotkeyFailures = hotkeyManager?.rebind(loaded.config.keymap) ?? []
        if !hotkeyFailures.isEmpty {
            showOperatorFeedback("\(hotkeyFailures.count) hotkey(s) could not be registered", tone: .error)
        }

        let activeConfig = configByRefreshingManagedRules(loaded.config)
        config = activeConfig
        configHealthy = true
        startupConfigFailure = nil
        configWarning = nil
        await worldActor.reloadConfig(activeConfig)
        overlay.updateConfig(border: activeConfig.border, hud: activeConfig.hud)
        eventTapClient?.updateModifier(activeConfig.dragModifier)
        logStartupConfig(loaded)
        menubar.updateConfigStatus(.loaded)
        if servicesStarted {
            updateRuntimeReadiness(operationalReadiness)
        }
        reporter.info("Config reload completed (\(reason))")
        showOperatorFeedback("Config reloaded", tone: .success)
        workbenchController.refreshIfVisible()
    }

    func activateManagedRules(_ rules: [ManagedWindowRule]) async throws {
        if case .failure(let error) = validateManagedRules(rules, zones: Set(config.zones.map(\.id))) {
            throw error
        }
        managedRules = rules
        managedRulesWarning = nil
        let activeConfig = config.withManagedRules(rules)
        config = activeConfig
        await worldActor.reloadConfig(activeConfig)
        reporter.info("Activated \(rules.count) managed window rules from Layout Workbench")
    }

    func applyWorkbenchPlan(
        _ result: CommandPlanResult,
        intent: WorkbenchIntent
    ) async -> Bool {
        await applyPlannedLayout(
            result,
            operation: intent.label,
            persistReason: "workbench \(intent.label.lowercased())",
            retryOnClamp: intent != .shuffle,
            replanAfterClamp: { [worldActor] in
                switch await planWorkbenchIntent(intent, with: worldActor) {
                case .success(let plan):
                    return .success(plan)
                case .failure(.command(let error)):
                    return .failure(error)
                case .failure(let failure):
                    return .failure(.configInvalid(workbenchExplanation(for: failure).reason))
                }
            }
        )
    }

    private func backgroundStartupConfigLoad() async -> Result<StartupConfigLoad, StartupConfigError> {
        let request = startupArguments.startupConfigRequest
        return await Task.detached(priority: .userInitiated) {
            switch request {
            case .success(let request):
                return StartupConfigLoader(
                    configURL: request.url,
                    missingFilePolicy: request.missingFilePolicy
                ).load()
            case .failure(let error):
                return .failure(error)
            }
        }.value
    }
}
