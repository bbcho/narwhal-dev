import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

struct LayoutTransactionCommit: Equatable, Sendable {
    let appliedFrames: [WindowID: CGRect]
    let focusUpdate: PlannedLayoutFocusUpdate?
    let affectedWorkspaces: Set<WorkspaceKey>
}

enum LayoutTransactionOutcome: Equatable, Sendable {
    case committed(LayoutTransactionCommit)
    case failed(operation: String, reason: String, restoredFrames: [WindowID: CGRect])
    case reconciliationRequired(workspaces: Set<WorkspaceKey>, reason: String)
}

func layoutTransactionAffectedWindowIDs(_ plan: CommandPlanResult) -> Set<WindowID> {
    Set(plan.desiredLayout.delta.moves.keys)
        .union(plan.desiredLayout.delta.raises)
        .union(plan.desiredLayout.delta.hides)
        .union(plan.desiredLayout.delta.shows)
}

@MainActor
final class LayoutTransactionCoordinator {
    private let worldActor: WorldActor
    private let frameTransaction: LayoutFrameTransaction

    init(worldActor: WorldActor, frameTransaction: LayoutFrameTransaction) {
        self.worldActor = worldActor
        self.frameTransaction = frameTransaction
    }

    func execute(
        initialPlan: CommandPlanResult,
        operation: String,
        retryOnConstraint: Bool,
        preserving preservedFrames: [WindowID: CGRect],
        replan: @escaping @MainActor () async -> Result<CommandPlanResult, CommandError>,
        reconcileLiveWorld: @escaping @MainActor () async -> EnvironmentRefreshResult
    ) async -> LayoutTransactionOutcome {
        var plan = initialPlan
        var retryState = LayoutClampRetryState(
            maxAttempts: initialPlan.desiredLayout.delta.moves.count
        )
        var affectedWorkspaces = affectedWorkspaceKeys(for: initialPlan)

        while true {
            let frameOutcome = await frameTransaction.execute(
                plan,
                preserving: preservedFrames
            ) { [worldActor] in
                await worldActor.isCurrent(plan)
            }

            switch frameOutcome {
            case .applied(let originalFrames, let appliedFrames):
                guard await worldActor.commit(plan, appliedFrames: appliedFrames) else {
                    let staleFailure = LayoutFrameTransactionFailure(
                        windowID: nil,
                        stage: .currency,
                        message: "layout plan became stale before commit"
                    )
                    let rollback = await frameTransaction.rollback(
                        plan,
                        originalFrames: originalFrames,
                        preserving: preservedFrames,
                        failure: staleFailure
                    )
                    return await terminalOutcome(
                        rollback,
                        operation: operation,
                        plan: plan,
                        affectedWorkspaces: affectedWorkspaces,
                        reconcileLiveWorld: reconcileLiveWorld
                    )
                }
                for key in affectedWorkspaces {
                    await worldActor.clearWorkspaceReconciliationIssue(for: key)
                }
                return .committed(LayoutTransactionCommit(
                    appliedFrames: appliedFrames,
                    focusUpdate: focusUpdate(for: plan, appliedFrames: appliedFrames),
                    affectedWorkspaces: affectedWorkspaces
                ))

            case .constraintObserved(let originalFrames, let observations, let failure):
                guard await worldActor.isCurrent(plan) else {
                    return .failed(
                        operation: operation,
                        reason: "layout plan became stale after restoring constrained frames",
                        restoredFrames: originalFrames
                    )
                }
                await worldActor.recordObservedConstraints(observations)
                guard retryOnConstraint,
                      let nextRetryState = retryState.recording(observations)
                else {
                    return .failed(
                        operation: operation,
                        reason: "constraint retry exhausted: \(failure.message)",
                        restoredFrames: originalFrames
                    )
                }
                retryState = nextRetryState
                switch await replan() {
                case .success(let retryPlan):
                    plan = retryPlan
                    affectedWorkspaces.formUnion(affectedWorkspaceKeys(for: retryPlan))
                case .failure(let error):
                    return .failed(
                        operation: operation,
                        reason: "constraint replan failed: \(error.message)",
                        restoredFrames: originalFrames
                    )
                }

            case .rolledBack(let originalFrames, let failure):
                return .failed(
                    operation: operation,
                    reason: failure.message,
                    restoredFrames: originalFrames
                )

            case .reconciliationRequired:
                return await terminalOutcome(
                    frameOutcome,
                    operation: operation,
                    plan: plan,
                    affectedWorkspaces: affectedWorkspaces,
                    reconcileLiveWorld: reconcileLiveWorld
                )
            }
        }
    }

    private func terminalOutcome(
        _ frameOutcome: LayoutFrameTransactionOutcome,
        operation: String,
        plan: CommandPlanResult,
        affectedWorkspaces: Set<WorkspaceKey>,
        reconcileLiveWorld: @MainActor () async -> EnvironmentRefreshResult
    ) async -> LayoutTransactionOutcome {
        switch frameOutcome {
        case .rolledBack(let originalFrames, let failure):
            return .failed(
                operation: operation,
                reason: failure.message,
                restoredFrames: originalFrames
            )
        case .reconciliationRequired(_, _, let failure, let rollbackFailures):
            _ = await reconcileLiveWorld()
            let rollbackSummary = rollbackFailures.map { entry in
                let window = entry.windowID.map(\.description) ?? "unknown window"
                return "\(window): \(entry.message)"
            }.joined(separator: "; ")
            let reason = "\(failure.message); rollback failed: \(rollbackSummary)"
            let issue = WorkspaceReconciliationIssue(
                operation: operation,
                windowIDs: Array(affectedWindowIDs(for: plan)),
                reason: reason
            )
            for key in affectedWorkspaces {
                await worldActor.recordWorkspaceReconciliationIssue(issue, for: key)
            }
            return .reconciliationRequired(workspaces: affectedWorkspaces, reason: reason)
        case .applied, .constraintObserved:
            return .failed(
                operation: operation,
                reason: "invalid terminal frame transaction outcome",
                restoredFrames: [:]
            )
        }
    }

    private func focusUpdate(
        for plan: CommandPlanResult,
        appliedFrames: [WindowID: CGRect]
    ) -> PlannedLayoutFocusUpdate? {
        guard let focusedWindowID = plan.focusedWindowID else { return nil }
        guard let frame = appliedFrames[focusedWindowID]
            ?? plan.desiredLayout.layout.tiled[focusedWindowID]
        else {
            return .clear
        }
        return .target(windowID: focusedWindowID, frame: frame)
    }

    private func affectedWorkspaceKeys(for plan: CommandPlanResult) -> Set<WorkspaceKey> {
        let keys = affectedWindowIDs(for: plan).reduce(into: Set<WorkspaceKey>()) { result, windowID in
            if let key = workspaceKey(forWindow: windowID, in: plan.sourceWorld) {
                result.insert(key)
            }
            if let key = workspaceKey(forWindow: windowID, in: plan.plannedWorld) {
                result.insert(key)
            }
        }
        if !keys.isEmpty { return keys }
        return Set(activeWorkspaceKeys(in: plan.plannedWorld) + activeWorkspaceKeys(in: plan.sourceWorld))
    }

    private func affectedWindowIDs(for plan: CommandPlanResult) -> Set<WindowID> {
        layoutTransactionAffectedWindowIDs(plan)
    }
}
