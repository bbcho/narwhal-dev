import AppKit
import CoreGraphics
import NarwhalAppSupport
import NarwhalCore

extension AppDelegate {
    @MainActor
    @discardableResult
    func performFocusDirection(_ direction: Direction) async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Focus \(direction.rawValue) skipped because Accessibility is not trusted")
            showOperatorFeedback("Focus failed: Accessibility not trusted", tone: .error)
            return false
        }

        let axFocusedWindowID: WindowID?
        let axFocusError: AXClientError?
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            axFocusedWindowID = value.id
            axFocusError = nil
        case .failure(let error):
            axFocusedWindowID = nil
            axFocusError = error
        }

        let displays = displayClient.currentDisplays()
        let environment = await refreshEnvironmentLocked(
            reason: "pre-focus \(direction.rawValue)",
            displays: displays,
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Focus \(direction.rawValue) rejected before planning: active Space unavailable")
            showOperatorFeedback("Focus failed: active Space unavailable", tone: .error)
            return false
        }
        let focusedWindowID: WindowID
        if let axFocusedWindowID {
            focusedWindowID = axFocusedWindowID
            await worldActor.recordExternalFocus(axFocusedWindowID)
        } else if let fallback = await worldActor.focusedWindowFallback() {
            focusedWindowID = fallback.id
            reporter.info("Focus \(direction.rawValue) using stored focus fallback \(fallback.id.description) after AX focus read failed: \(axFocusError?.description ?? "unknown")")
        } else {
            reporter.error("Focus \(direction.rawValue) failed reading focused window: \(axFocusError?.description ?? "unknown")")
            showOperatorFeedback("Focus failed: no focused window", tone: .error)
            return false
        }

        switch await worldActor.planFocusDirection(from: focusedWindowID, direction: direction) {
        case .success(let result):
            return await focusWindow(result, reason: "focus \(direction.rawValue)")
        case .failure(let error):
            if case .noNeighbor = error {
                reporter.info("Focus \(direction.rawValue) has no neighboring window")
                showOperatorFeedback("No window \(direction.rawValue)", tone: .info, showsHUD: false)
                return false
            }
            reporter.error("Focus \(direction.rawValue) rejected by core: \(error.message)")
            showOperatorFeedback("Focus failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    func performFocusCycle(_ direction: FocusCycleDirection) async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Focus cycle \(direction.rawValue) skipped because Accessibility is not trusted")
            showOperatorFeedback("Focus cycle failed: Accessibility not trusted", tone: .error)
            return false
        }

        var focusedWindowID: WindowID?
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            focusedWindowID = value.id
        case .failure:
            focusedWindowID = nil
        }

        let environment = await refreshEnvironmentLocked(
            reason: "pre-focus-cycle \(direction.rawValue)",
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Focus cycle \(direction.rawValue) rejected before planning: active Space unavailable")
            showOperatorFeedback("Focus cycle failed: active Space unavailable", tone: .error)
            return false
        }
        if let focusedWindowID {
            await worldActor.recordExternalFocus(focusedWindowID)
        } else if let fallback = await worldActor.focusedWindowFallback() {
            focusedWindowID = fallback.id
            await worldActor.recordExternalFocus(fallback.id)
        }

        switch await worldActor.planFocusCycleCandidates(from: focusedWindowID, direction: direction) {
        case .success(let allResults):
            let results = allResults.filter { !axRaiseBlocklist.contains($0.window.id) }
            let droppedCount = allResults.count - results.count
            if droppedCount > 0 {
                reporter.info("Focus cycle \(direction.rawValue) skipped \(droppedCount) AX-raise-hostile candidate(s)")
            }
            reporter.info("Focus cycle \(direction.rawValue) planned \(results.count) candidate(s)")
            if results.isEmpty {
                showOperatorFeedback("No cyclable window", tone: .info, showsHUD: false)
                return false
            }
            for (index, result) in results.enumerated() {
                if await focusWindow(
                    result,
                    reason: "focus cycle \(direction.rawValue)",
                    suppressFailureFeedback: index < results.count - 1
                ) {
                    return true
                }
            }
            reporter.error("Focus cycle \(direction.rawValue) exhausted \(results.count) candidate(s)")
            showOperatorFeedback("Focus cycle failed", tone: .error)
            return false
        case .failure(let error):
            reporter.error("Focus cycle \(direction.rawValue) rejected by core: \(error.message)")
            showOperatorFeedback("Focus cycle failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    @discardableResult
    func performFocusPrevious() async -> Bool {
        guard AccessibilityTrust.current(prompt: false).isTrusted else {
            reporter.error("Focus previous skipped because Accessibility is not trusted")
            showOperatorFeedback("Focus previous failed: Accessibility not trusted", tone: .error)
            return false
        }

        var focusedWindowID: WindowID?
        switch axClient.focusedWindowSnapshot() {
        case .success(let value):
            focusedWindowID = value.id
        case .failure:
            focusedWindowID = nil
        }

        let environment = await refreshEnvironmentLocked(
            reason: "pre-focus-previous",
            reconciliationMode: .observeOnly
        )
        guard environment.activeSpace != nil else {
            reporter.error("Focus previous rejected before planning: active Space unavailable")
            showOperatorFeedback("Focus previous failed: active Space unavailable", tone: .error)
            return false
        }
        if let focusedWindowID {
            await worldActor.recordExternalFocus(focusedWindowID)
        } else if let fallback = await worldActor.focusedWindowFallback() {
            focusedWindowID = fallback.id
            await worldActor.recordExternalFocus(fallback.id)
        }

        switch await worldActor.planFocusPrevious(from: focusedWindowID) {
        case .success(let result):
            return await focusWindow(result, reason: "focus previous")
        case .failure(let error):
            reporter.error("Focus previous rejected by core: \(error.message)")
            showOperatorFeedback("Focus previous failed: \(error.message)", tone: .error)
            return false
        }
    }

    @MainActor
    func focusWindow(
        _ result: FocusPlanResult,
        reason: String,
        suppressFailureFeedback: Bool = false
    ) async -> Bool {
        switch await axClient.focusWindow(result.window) {
        case .success:
            echoSuppressor.expectFocus(windowID: result.window.id)
            await worldActor.recordExternalFocus(result.window.id)
            updateOperatingStatus { $0.focusedWindowID = result.window.id }
            setFocusBorder(FocusBorderTarget(window: result.window, frame: result.frame))
            reporter.info("\(reason) completed target=\(result.window.id.description)")
            showOperatorFeedback("\(reason) -> \(result.window.id.description)", tone: .success, showsHUD: false)
            return true
        case .failure(let error):
            reporter.error(
                "\(reason) failed focusing \(result.window.id.description) "
                + "(bundle=\(result.window.bundleID.raw) title=\"\(result.window.title)\"): "
                + error.description
            )
            if shouldRemoveFailedFocusTarget(error, reason: reason) {
                await worldActor.removeWindowFromActiveSpace(result.window.id)
                await updateTiledBordersFromWorld()
                reporter.info("Removed stale focus target \(result.window.id.description) from active Space after focus failure")
            }
            if shouldBlocklistFromCycle(error) {
                if axRaiseBlocklist.insert(result.window.id).inserted {
                    reporter.info(
                        "Added \(result.window.id.description) (bundle=\(result.window.bundleID.raw)) "
                        + "to AX-raise blocklist; future focus cycles will skip it"
                    )
                }
            }
            if !suppressFailureFeedback {
                showOperatorFeedback("\(reason) failed", tone: .error)
            }
            return false
        }
    }

    private func shouldBlocklistFromCycle(_ error: AXClientError) -> Bool {
        // Permanent (for the session) AX-raise refusals — the target app does not
        // expose kAXRaiseAction at all (e.g., System Settings). Env refresh will
        // keep re-discovering the window, so we must remember it ourselves.
        if case let .performActionFailed(action, axError) = error,
           action == kAXRaiseAction,
           axError == .attributeUnsupported || axError == .actionUnsupported {
            return true
        }
        return false
    }

    private func shouldRemoveFailedFocusTarget(_ error: AXClientError, reason: String) -> Bool {
        let isCycling = reason.hasPrefix("focus cycle") || reason == "focus previous"
        switch error {
        case .windowElementNotFound:
            return true
        case .performActionFailed(let action, let axError):
            // .cannotComplete: app unresponsive / window gone. .attributeUnsupported /
            // .actionUnsupported: the target app doesn't expose kAXRaiseAction at all
            // (some Electron/web apps, some control panels, some menu-only apps). In
            // all three cases the window is not focus-cyclable; drop it from the active
            // Space so the cycle stops getting stuck on it.
            return isCycling
                && action == kAXRaiseAction
                && (axError == .cannotComplete
                    || axError == .attributeUnsupported
                    || axError == .actionUnsupported)
        case .applicationActivateFailed:
            return isCycling
        case .copyAttributeFailed,
             .missingFocusedWindow,
             .focusedWindowWrongType,
             .pidUnavailable,
             .pointAttributeInvalid,
             .sizeAttributeInvalid,
             .boolAttributeInvalid,
             .focusedWindowUnmatchedToCGWindow,
             .windowsAttributeInvalid,
             .setAttributeFailed,
             .automationFailed,
             .frameDidNotConverge,
             .frameReadbackDisagreed,
             .invalidFrame,
             .visibleWindowListUnavailable,
             .windowServerFrameUnavailable,
             .draggableTitleBarPointUnavailable,
             .windowNotRaised:
            return false
        }
    }
}
