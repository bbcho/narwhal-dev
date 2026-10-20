import AppKit
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore
import NarwhalIPC

extension AppDelegate {
    @MainActor
    func handleIPCCommand(_ command: IPCCommandDTO) async -> IPCReplyDTO {
        await workspaceMutationGate.perform {
            await self.handleSerializedIPCCommand(command)
        }
    }

    @MainActor
    private func handleSerializedIPCCommand(_ command: IPCCommandDTO) async -> IPCReplyDTO {
        let commandID = CommandID(raw: "ipc-\(UUID().uuidString)")
        switch command {
        case .status:
            return .diagnostics(commandID: commandID, value: await runtimeDiagnostics())
        case .resetLayout:
            await performResetLayout(logPrefix: "IPC reset", persistReason: "ipc reset")
            return .ok(commandID: commandID)
        case .quit:
            reporter.info("IPC quit requested")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                await self?.requestTermination()
            }
            return .ok(commandID: commandID)
        case .pushFocused(let direction):
            if await performPush(direction) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "push_failed",
                message: "Focused push \(direction.rawValue) failed; see NarwhalApp log"
            )
        case .push(let windowID, let direction):
            if let failure = await performExplicitPush(windowID: windowID, direction: direction) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .swapFocused(let direction):
            if await performSwap(direction) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "swap_failed",
                message: "Focused swap \(direction.rawValue) failed; see NarwhalApp log"
            )
        case .swap(let windowID, let direction):
            if let failure = await performExplicitSwap(windowID: windowID, direction: direction) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .resizeFocused(let direction, let delta):
            if await performResize(direction, delta: delta) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "resize_failed",
                message: "Focused resize \(direction.rawValue) failed; see NarwhalApp log"
            )
        case .resize(let windowID, let direction, let delta):
            if let failure = await performExplicitResize(windowID: windowID, direction: direction, delta: delta) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .center(let windowID):
            if let failure = await performExplicitCenter(windowID: windowID) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .eject(let windowID):
            if let failure = await performExplicitEject(windowID: windowID) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .toggleFloat(let windowID):
            if let failure = await performExplicitToggleFloat(windowID: windowID) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .balance:
            if let failure = await performActiveSpaceBalance(
                operation: "IPC balance",
                refreshReason: "ipc balance",
                persistReason: "ipc balance"
            ) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        case .focusDirection(let direction):
            if await performFocusDirection(direction) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "focus_failed",
                message: "Focus \(direction.rawValue) failed; see NarwhalApp log"
            )
        case .focusCycle(let direction):
            if await performFocusCycle(direction) {
                return .ok(commandID: commandID)
            }
            return .error(
                commandID: commandID,
                code: "focus_failed",
                message: "Focus cycle \(direction.rawValue) failed; see NarwhalApp log"
            )
        case .focus(let windowID):
            if let failure = await performExplicitFocus(windowID: windowID) {
                return .error(commandID: commandID, code: failure.code, message: failure.message)
            }
            return .ok(commandID: commandID)
        }
    }

    @MainActor
    private func performActiveSpaceBalance(
        operation: String,
        refreshReason: String,
        persistReason: String
    ) async -> CommandExecutionFailure? {
        switch await requireIPCPlanningEnvironment(operation: operation, refreshReason: refreshReason) {
        case .success(let activeSpace):
            reporter.info("\(operation) selected active Space \(activeSpace.raw)")
        case .failure(let failure):
            return failure
        }

        switch await worldActor.planBalanceActiveSpace() {
        case .success(let result):
            if await applyPlannedBalance(
                result,
                operation: operation,
                persistReason: persistReason,
                retryOnClamp: true,
                replanAfterClamp: {
                    await self.worldActor.planBalanceActiveSpace()
                }
            ) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: "\(operation) layout write failed; see NarwhalApp log"
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
        }
    }

    @MainActor
    private func requireIPCPlanningEnvironment(
        operation: String,
        refreshReason: String
    ) async -> Result<SpaceID, CommandExecutionFailure> {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            return .failure(CommandExecutionFailure(
                code: "accessibility_not_trusted",
                message: "Accessibility permission is not trusted"
            ))
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironmentLocked(
            reason: refreshReason,
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard let activeSpace = environment.activeSpace else {
            return .failure(CommandExecutionFailure(code: "active_space_unavailable", message: "active Space unavailable"))
        }
        guard case .complete = environment.quality else {
            return .failure(CommandExecutionFailure(
                code: "environment_incomplete",
                message: "\(operation) requires a complete AX snapshot; got \(AppDelegateText.describe(environment.quality))"
            ))
        }
        return .success(activeSpace)
    }

    @MainActor
    private func performExplicitLayoutPlan(
        operation: String,
        refreshReason: String,
        applyFailureMessage: String,
        plan: () async -> Result<CommandPlanResult, CommandError>,
        apply: (CommandPlanResult) async -> Bool
    ) async -> CommandExecutionFailure? {
        if case .failure(let failure) = await requireIPCPlanningEnvironment(
            operation: operation,
            refreshReason: refreshReason
        ) {
            return failure
        }

        switch await plan() {
        case .success(let result):
            if await apply(result) {
                return nil
            }
            return CommandExecutionFailure(
                code: "apply_failed",
                message: applyFailureMessage
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
        }
    }

    @MainActor
    private func performExplicitPush(windowID: WindowID, direction: Direction) async -> CommandExecutionFailure? {
        await performExplicitLayoutPlan(
            operation: "IPC push",
            refreshReason: "ipc push \(direction.rawValue)",
            applyFailureMessage: "Push \(direction.rawValue) layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planPush(windowID, direction: direction) },
            apply: { result in
                await self.applyPlannedPush(result, direction: direction, retryOnClamp: true)
            }
        )
    }

    @MainActor
    private func performExplicitCenter(windowID: WindowID) async -> CommandExecutionFailure? {
        await performExplicitLayoutPlan(
            operation: "IPC center",
            refreshReason: "ipc center",
            applyFailureMessage: "Center layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planCenter(windowID) },
            apply: { result in
                await self.applyPlannedCenter(result, windowID: windowID, retryOnClamp: true)
            }
        )
    }

    @MainActor
    private func performExplicitEject(windowID: WindowID) async -> CommandExecutionFailure? {
        await performExplicitLayoutPlan(
            operation: "IPC eject",
            refreshReason: "ipc eject",
            applyFailureMessage: "Eject layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planEject(windowID) },
            apply: { result in
                await self.applyPlannedEject(result, windowID: windowID, retryOnClamp: true)
            }
        )
    }

    @MainActor
    private func performExplicitToggleFloat(windowID: WindowID) async -> CommandExecutionFailure? {
        await performExplicitLayoutPlan(
            operation: "IPC toggleFloat",
            refreshReason: "ipc toggle float",
            applyFailureMessage: "Toggle float layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planToggleFloat(windowID) },
            apply: { result in
                await self.applyPlannedToggleFloat(result, windowID: windowID, retryOnClamp: true)
            }
        )
    }

    @MainActor
    private func performExplicitFocus(windowID: WindowID) async -> CommandExecutionFailure? {
        if case .failure(let failure) = await requireIPCPlanningEnvironment(
            operation: "IPC focus",
            refreshReason: "ipc focus"
        ) {
            return failure
        }

        switch await worldActor.planFocus(windowID) {
        case .success(let result):
            if await focusWindow(result, reason: "ipc focus") {
                return nil
            }
            return CommandExecutionFailure(
                code: "focus_failed",
                message: "Focus \(windowID.description) failed; see NarwhalApp log"
            )
        case .failure(let error):
            return CommandExecutionFailure(code: error.code, message: error.message)
        }
    }

    @MainActor
    private func performExplicitSwap(windowID: WindowID, direction: Direction) async -> CommandExecutionFailure? {
        await performExplicitLayoutPlan(
            operation: "IPC swap",
            refreshReason: "ipc swap \(direction.rawValue)",
            applyFailureMessage: "Swap \(direction.rawValue) layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planSwap(windowID, direction: direction) },
            apply: { result in
                await self.applyPlannedSwap(result, windowID: windowID, direction: direction, retryOnClamp: true)
            }
        )
    }

    @MainActor
    private func performExplicitResize(
        windowID: WindowID,
        direction: Direction,
        delta: Double
    ) async -> CommandExecutionFailure? {
        await performExplicitLayoutPlan(
            operation: "IPC resize",
            refreshReason: "ipc resize \(direction.rawValue)",
            applyFailureMessage: "Resize \(direction.rawValue) layout write failed; see NarwhalApp log",
            plan: { await self.worldActor.planResize(windowID, direction: direction, delta: delta) },
            apply: { result in
                await self.applyPlannedResize(
                    result,
                    windowID: windowID,
                    direction: direction,
                    deltas: [delta],
                    retryOnClamp: true
                )
            }
        )
    }
}
