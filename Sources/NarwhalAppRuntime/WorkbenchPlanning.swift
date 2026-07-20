import NarwhalAppSupport
import NarwhalCore

enum WorkbenchIntent: Equatable, Sendable {
    case push(windowID: WindowID, direction: Direction)
    case resize(windowID: WindowID, direction: Direction, delta: Double)
    case eject(windowID: WindowID)
    case balance(windowID: WindowID)
    case shuffle
    case cascade
    case reset
    case undo
    case redo
    case namedLayout(NamedLayout, spaceID: SpaceID, allowPartial: Bool)

    var operation: LayoutOperation {
        switch self {
        case .push(_, let direction): return .push(direction)
        case .resize(_, let direction, _): return .resize(direction)
        case .eject: return .eject
        case .balance: return .balance
        case .shuffle: return .shuffle
        case .cascade: return .cascade
        case .reset: return .reset
        case .undo: return .directManipulation
        case .redo: return .directManipulation
        case .namedLayout(let layout, _, _): return .applyTemplate(layout.name)
        }
    }

    var label: String {
        switch self {
        case .undo: return "Undo Layout"
        case .redo: return "Redo Layout"
        default: return operation.label
        }
    }

    var requiresDestructiveConfirmation: Bool {
        if case .reset = self { return true }
        return false
    }
}

enum WorkbenchPlanFailure: Error, Equatable, Sendable {
    case command(CommandError)
    case namedLayout(NamedLayoutApplicationError)
}

struct WorkbenchPlanExplanation: Equatable, Sendable {
    let title: String
    let reason: String
    let canRetryAsPartial: Bool
}

func planWorkbenchIntent(
    _ intent: WorkbenchIntent,
    with actor: WorldActor
) async -> Result<CommandPlanResult, WorkbenchPlanFailure> {
    switch intent {
    case .push(let windowID, let direction):
        return await actor.planPush(windowID, direction: direction).mapError(WorkbenchPlanFailure.command)
    case .resize(let windowID, let direction, let delta):
        return await actor.planResize(windowID, direction: direction, delta: delta)
            .mapError(WorkbenchPlanFailure.command)
    case .eject(let windowID):
        return await actor.planEject(windowID).mapError(WorkbenchPlanFailure.command)
    case .balance(let windowID):
        return await actor.planBalanceWorkspace(containing: windowID).mapError(WorkbenchPlanFailure.command)
    case .shuffle:
        return await actor.planShuffleActiveSpace().mapError(WorkbenchPlanFailure.command)
    case .cascade:
        return await actor.planCascadeActiveSpace().mapError(WorkbenchPlanFailure.command)
    case .reset:
        return await actor.planResetLayoutMemory().mapError(WorkbenchPlanFailure.command)
    case .undo:
        return await actor.planUndoLastLayout()
            .flatMap { $0.map(Result.success) ?? .failure(.configInvalid("There is no layout change to undo in this Space.")) }
            .mapError(WorkbenchPlanFailure.command)
    case .redo:
        return await actor.planRedoLastLayout()
            .flatMap { $0.map(Result.success) ?? .failure(.configInvalid("There is no layout change to redo in this Space.")) }
            .mapError(WorkbenchPlanFailure.command)
    case .namedLayout(let layout, let spaceID, let allowPartial):
        switch await actor.planNamedLayout(layout, spaceID: spaceID, allowPartial: allowPartial) {
        case .success(let plan):
            return .success(plan)
        case .failure(.command(let error)):
            return .failure(.command(error))
        case .failure(.application(let error)):
            return .failure(.namedLayout(error))
        }
    }
}

func workbenchExplanation(for failure: WorkbenchPlanFailure) -> WorkbenchPlanExplanation {
    switch failure {
    case .command(let error):
        let explanation = commandExplanation(for: error)
        return WorkbenchPlanExplanation(
            title: explanation.title,
            reason: explanation.reason,
            canRetryAsPartial: false
        )
    case .namedLayout(.validation):
        return WorkbenchPlanExplanation(
            title: "Named layout is invalid",
            reason: "The saved template contains invalid structure or match criteria. Edit or recreate it before applying.",
            canRetryAsPartial: false
        )
    case .namedLayout(.inactiveSpace):
        return WorkbenchPlanExplanation(
            title: "Space is not active",
            reason: "Switch this display to the selected Space before applying its named layout.",
            canRetryAsPartial: false
        )
    case .namedLayout(.partialMatch(let result)):
        let slots = result.unmatchedSlots.count
        let displays = result.missingDisplaySlots.count
        return WorkbenchPlanExplanation(
            title: "Named layout has unmatched targets",
            reason: namedLayoutMismatchReason(result, slotCount: slots, displayCount: displays),
            canRetryAsPartial: !result.matches.isEmpty
        )
    case .namedLayout(.noMatchingWindows):
        return WorkbenchPlanExplanation(
            title: "No windows match this layout",
            reason: "Open the applications named by the layout or edit its window matchers.",
            canRetryAsPartial: false
        )
    case .namedLayout(.unsatisfiable(let conflict)):
        let explanation = commandExplanation(for: .layoutUnsatisfiable(conflict))
        return WorkbenchPlanExplanation(
            title: explanation.title,
            reason: explanation.reason,
            canRetryAsPartial: false
        )
    }
}

private func namedLayoutMismatchReason(
    _ result: NamedLayoutMatchResult,
    slotCount: Int,
    displayCount: Int
) -> String {
    var lines = [
        "\(slotCount) window slot\(slotCount == 1 ? "" : "s") and \(displayCount) display\(displayCount == 1 ? "" : "s") are unavailable. Unmatched windows will remain floating."
    ]
    if !result.missingDisplaySlots.isEmpty {
        lines.append("Missing displays: " + result.missingDisplaySlots.map { "D\($0)" }.joined(separator: ", "))
    }
    if !result.unmatchedSlots.isEmpty {
        lines.append("Unmatched slots:")
        lines.append(contentsOf: result.unmatchedSlots.map { slot in
            "• \(slot.slotID.rawValue) on D\(slot.targetDisplaySlot): \(matcherDescription(slot.matcher))"
        })
    }
    if !result.unmatchedWindows.isEmpty {
        lines.append("Unmatched windows: " + result.unmatchedWindows.map { "W\($0.raw)" }.joined(separator: ", "))
    }
    return lines.joined(separator: "\n")
}

private func matcherDescription(_ matcher: LayoutWindowMatcher) -> String {
    var parts = [matcher.bundleID]
    if let role = matcher.role { parts.append(role) }
    if let title = matcher.title {
        switch title {
        case .exact(let value): parts.append("title = \(value)")
        case .regex(let value): parts.append("title ~= \(value)")
        }
    }
    return parts.joined(separator: " · ")
}
