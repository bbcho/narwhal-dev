import CoreGraphics
import Foundation
import NarwhalAppSupport
import NarwhalCore

@MainActor
final class EventTapClient {
    private var modifier: ModifierSet
    private let reporter: StartupReporter
    private let dragChanged: (CGPoint) -> Void
    private let dragEnded: () -> Void
    private let drop: (CGPoint) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dragState = DragGestureState.empty

    init(
        modifier: ModifierSet,
        reporter: StartupReporter,
        dragChanged: @escaping (CGPoint) -> Void,
        dragEnded: @escaping () -> Void,
        drop: @escaping (CGPoint) -> Void
    ) {
        self.modifier = modifier
        self.reporter = reporter
        self.dragChanged = dragChanged
        self.dragEnded = dragEnded
        self.drop = drop
    }

    func start() throws {
        guard eventTap == nil else { return }

        let mask = eventMask([.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw EventTapError.createFailed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw EventTapError.runLoopSourceFailed
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        reporter.info("Drag zones ready with modifier \(describe(modifier))")
    }

    func updateModifier(_ modifier: ModifierSet) {
        applyDragInput(.cancel)
        self.modifier = modifier
        reporter.info("Updated drag-zone modifier to \(describe(modifier))")
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        applyDragInput(.cancel)
    }

    private func handle(type: CGEventType, location: CGPoint, flagsRaw: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch type {
        case .tapDisabledByTimeout:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                reporter.error("Drag-zone event tap was disabled by timeout; re-enabled")
            }
            applyDragInput(.cancel)
        case .tapDisabledByUserInput:
            reporter.error("Drag-zone event tap disabled by user input")
            applyDragInput(.cancel)
        case .leftMouseDown:
            applyDragInput(.mouseDown(location: location, modifiers: modifiers(from: flagsRaw)))
        case .leftMouseDragged:
            applyDragInput(.mouseDragged(location: location, modifiers: modifiers(from: flagsRaw)))
        case .leftMouseUp:
            applyDragInput(.mouseUp(location: location))
        default:
            break
        }
    }

    private func applyDragInput(_ input: DragGestureInput) {
        let transition = reduceDragGesture(
            state: dragState,
            input: input,
            requiredModifier: modifier
        )
        dragState = transition.state
        applyDragEffects(transition.effects)
    }

    private func applyDragEffects(_ effects: [DragGestureEffect]) {
        for effect in effects {
            switch effect {
            case .preview(let location):
                dragChanged(location)
            case .endPreview:
                dragEnded()
            case .drop(let location):
                drop(location)
            }
        }
    }

    // Safe iff the run loop source is on the main loop (see start() / CFRunLoopGetMain).
    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let client = Unmanaged<EventTapClient>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated {
            client.handle(type: type, location: event.location, flagsRaw: event.flags.rawValue)
        }
        return Unmanaged.passUnretained(event)
    }
}

enum EventTapError: Error, CustomStringConvertible {
    case createFailed
    case runLoopSourceFailed

    var description: String {
        switch self {
        case .createFailed:
            return "CGEventTapCreate returned nil"
        case .runLoopSourceFailed:
            return "CFMachPortCreateRunLoopSource returned nil"
        }
    }
}

private func eventMask(_ types: [CGEventType]) -> CGEventMask {
    types.reduce(CGEventMask(0)) { result, type in
        result | (CGEventMask(1) << CGEventMask(type.rawValue))
    }
}

private func modifiers(from flagsRaw: UInt64) -> ModifierSet {
    let flags = CGEventFlags(rawValue: flagsRaw)
    var result = ModifierSet()
    if flags.contains(.maskShift) {
        result.insert(.shift)
    }
    if flags.contains(.maskCommand) {
        result.insert(.command)
    }
    if flags.contains(.maskAlternate) {
        result.insert(.option)
    }
    if flags.contains(.maskControl) {
        result.insert(.control)
    }
    return result
}

private func describe(_ modifiers: ModifierSet) -> String {
    let values = [
        modifiers.contains(.control) ? "control" : nil,
        modifiers.contains(.option) ? "option" : nil,
        modifiers.contains(.shift) ? "shift" : nil,
        modifiers.contains(.command) ? "command" : nil
    ].compactMap { $0 }
    return values.isEmpty ? "none" : values.joined(separator: "-")
}
