import CoreGraphics
import Foundation
import WinMgrCore

final class EventTapClient {
    private var modifier: ModifierSet
    private let reporter: StartupReporter
    private let drop: (CGPoint) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dragCandidate = false
    private var hasDragged = false

    init(
        modifier: ModifierSet,
        reporter: StartupReporter,
        drop: @escaping (CGPoint) -> Void
    ) {
        self.modifier = modifier
        self.reporter = reporter
        self.drop = drop
    }

    deinit {
        stop()
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
        self.modifier = modifier
        resetDrag()
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
        resetDrag()
    }

    private func handle(type: CGEventType, location: CGPoint, flagsRaw: UInt64) {
        switch type {
        case .tapDisabledByTimeout:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                reporter.error("Drag-zone event tap was disabled by timeout; re-enabled")
            }
        case .tapDisabledByUserInput:
            reporter.error("Drag-zone event tap disabled by user input")
        case .leftMouseDown:
            dragCandidate = modifiers(from: flagsRaw) == modifier
            hasDragged = false
        case .leftMouseDragged:
            guard dragCandidate else { return }
            if modifiers(from: flagsRaw) == modifier {
                hasDragged = true
            } else {
                resetDrag()
            }
        case .leftMouseUp:
            let shouldDrop = dragCandidate && hasDragged
            resetDrag()
            if shouldDrop {
                drop(location)
            }
        default:
            break
        }
    }

    private func resetDrag() {
        dragCandidate = false
        hasDragged = false
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let client = Unmanaged<EventTapClient>.fromOpaque(userInfo).takeUnretainedValue()
        client.handle(type: type, location: event.location, flagsRaw: event.flags.rawValue)
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
