import CoreGraphics
import Foundation

public struct AXExpectedFrameEcho: Equatable, Sendable {
    public let windowID: WindowID
    public let targetFrame: CGRect
    public let expiresAt: TimeInterval
    public let expectsMove: Bool
    public let expectsResize: Bool

    public init(
        windowID: WindowID,
        targetFrame: CGRect,
        expiresAt: TimeInterval,
        expectsMove: Bool,
        expectsResize: Bool
    ) {
        self.windowID = windowID
        self.targetFrame = targetFrame
        self.expiresAt = expiresAt
        self.expectsMove = expectsMove
        self.expectsResize = expectsResize
    }
}

public struct AXExpectedFocusEcho: Equatable, Sendable {
    public let windowID: WindowID
    public let expiresAt: TimeInterval

    public init(windowID: WindowID, expiresAt: TimeInterval) {
        self.windowID = windowID
        self.expiresAt = expiresAt
    }
}

public struct AXEchoState: Equatable, Sendable {
    public let frameEchoes: [AXExpectedFrameEcho]
    public let focusEchoes: [AXExpectedFocusEcho]

    public init(frameEchoes: [AXExpectedFrameEcho] = [], focusEchoes: [AXExpectedFocusEcho] = []) {
        self.frameEchoes = frameEchoes
        self.focusEchoes = focusEchoes
    }

    public static let empty = AXEchoState()
}

public struct AXEchoConsumeResult: Equatable, Sendable {
    public let isEcho: Bool
    public let state: AXEchoState

    public init(isEcho: Bool, state: AXEchoState) {
        self.isEcho = isEcho
        self.state = state
    }
}

public func expectFrameEcho(
    windowID: WindowID,
    targetFrame: CGRect,
    now: TimeInterval,
    ttl: TimeInterval,
    in state: AXEchoState
) -> AXEchoState {
    let pruned = pruneExpiredEchoes(in: state, now: now)
    let echo = AXExpectedFrameEcho(
        windowID: windowID,
        targetFrame: targetFrame,
        expiresAt: now + ttl,
        expectsMove: true,
        expectsResize: true
    )
    return AXEchoState(frameEchoes: pruned.frameEchoes + [echo], focusEchoes: pruned.focusEchoes)
}

public func expectFocusEcho(
    windowID: WindowID,
    now: TimeInterval,
    ttl: TimeInterval,
    in state: AXEchoState
) -> AXEchoState {
    let pruned = pruneExpiredEchoes(in: state, now: now)
    let echo = AXExpectedFocusEcho(windowID: windowID, expiresAt: now + ttl)
    return AXEchoState(frameEchoes: pruned.frameEchoes, focusEchoes: pruned.focusEchoes + [echo])
}

public func consumeExpectedEcho(
    _ event: AXEvent,
    now: TimeInterval,
    tolerance: CGFloat,
    in state: AXEchoState
) -> AXEchoConsumeResult {
    let pruned = pruneExpiredEchoes(in: state, now: now)
    switch event {
    case .windowMoved(let windowID, let frame):
        return consumeFrameEcho(windowID: windowID, frame: frame, component: .move, tolerance: tolerance, in: pruned)
    case .windowResized(let windowID, let size):
        return consumeFrameEcho(windowID: windowID, size: size, component: .resize, tolerance: tolerance, in: pruned)
    case .windowFocused(let windowID):
        return consumeFocusEcho(windowID: windowID, in: pruned)
    case .windowOpened, .windowClosed:
        return AXEchoConsumeResult(isEcho: false, state: pruned)
    }
}

private enum FrameEchoComponent {
    case move
    case resize
}

private func consumeFrameEcho(
    windowID: WindowID,
    frame: CGRect,
    component: FrameEchoComponent,
    tolerance: CGFloat,
    in state: AXEchoState
) -> AXEchoConsumeResult {
    consumeFrameEcho(windowID: windowID, component: component, tolerance: tolerance, in: state) { echo in
        originsApproximatelyMatch(echo.targetFrame.origin, frame.origin, tolerance: tolerance)
            || frameWriteApproximatelySettled(target: echo.targetFrame, actual: frame, tolerance: Double(tolerance))
    }
}

private func consumeFrameEcho(
    windowID: WindowID,
    size: CGSize,
    component: FrameEchoComponent,
    tolerance: CGFloat,
    in state: AXEchoState
) -> AXEchoConsumeResult {
    consumeFrameEcho(windowID: windowID, component: component, tolerance: tolerance, in: state) { echo in
        sizesApproximatelyMatch(echo.targetFrame.size, size, tolerance: tolerance)
            || frameSizeApproximatelySettled(target: echo.targetFrame.size, actual: size, tolerance: Double(tolerance))
    }
}

private func consumeFrameEcho(
    windowID: WindowID,
    component: FrameEchoComponent,
    tolerance: CGFloat,
    in state: AXEchoState,
    matches: (AXExpectedFrameEcho) -> Bool
) -> AXEchoConsumeResult {
    guard let index = state.frameEchoes.firstIndex(where: { echo in
        echo.windowID == windowID
            && matches(echo)
            && expects(component, in: echo)
    }) else {
        return AXEchoConsumeResult(isEcho: false, state: state)
    }

    return AXEchoConsumeResult(
        isEcho: true,
        state: AXEchoState(
            frameEchoes: echoesByConsumingFrameComponent(at: index, component: component, in: state.frameEchoes),
            focusEchoes: state.focusEchoes
        )
    )
}

private func consumeFocusEcho(windowID: WindowID, in state: AXEchoState) -> AXEchoConsumeResult {
    guard let index = state.focusEchoes.firstIndex(where: { $0.windowID == windowID }) else {
        return AXEchoConsumeResult(isEcho: false, state: state)
    }
    return AXEchoConsumeResult(
        isEcho: true,
        state: AXEchoState(
            frameEchoes: state.frameEchoes,
            focusEchoes: echoesByRemoving(at: index, from: state.focusEchoes)
        )
    )
}

private func pruneExpiredEchoes(in state: AXEchoState, now: TimeInterval) -> AXEchoState {
    AXEchoState(
        frameEchoes: state.frameEchoes.filter { $0.expiresAt > now },
        focusEchoes: state.focusEchoes.filter { $0.expiresAt > now }
    )
}

private func expects(_ component: FrameEchoComponent, in echo: AXExpectedFrameEcho) -> Bool {
    switch component {
    case .move:
        return echo.expectsMove
    case .resize:
        return echo.expectsResize
    }
}

private func echoByConsuming(_ component: FrameEchoComponent, in echo: AXExpectedFrameEcho) -> AXExpectedFrameEcho {
    switch component {
    case .move:
        return AXExpectedFrameEcho(
            windowID: echo.windowID,
            targetFrame: echo.targetFrame,
            expiresAt: echo.expiresAt,
            expectsMove: false,
            expectsResize: echo.expectsResize
        )
    case .resize:
        return AXExpectedFrameEcho(
            windowID: echo.windowID,
            targetFrame: echo.targetFrame,
            expiresAt: echo.expiresAt,
            expectsMove: echo.expectsMove,
            expectsResize: false
        )
    }
}

private func echoesByConsumingFrameComponent(
    at index: Int,
    component: FrameEchoComponent,
    in echoes: [AXExpectedFrameEcho]
) -> [AXExpectedFrameEcho] {
    let updated = echoByConsuming(component, in: echoes[index])
    let prefix = echoes.prefix(index)
    let suffix = echoes.dropFirst(index + 1)
    guard updated.expectsMove || updated.expectsResize else {
        return Array(prefix + suffix)
    }
    return Array(prefix + [updated] + suffix)
}

private func echoesByRemoving<Echo>(
    at index: Int,
    from echoes: [Echo]
) -> [Echo] {
    Array(echoes.prefix(index) + echoes.dropFirst(index + 1))
}

private func originsApproximatelyMatch(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat) -> Bool {
    abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
}

private func sizesApproximatelyMatch(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat) -> Bool {
    abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
}
