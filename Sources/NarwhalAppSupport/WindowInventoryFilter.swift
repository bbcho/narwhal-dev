import CoreGraphics
import Darwin
import Foundation
import NarwhalCore

public struct WindowInventoryRecord: Equatable, Sendable {
    public let id: WindowID
    public let ownerPID: pid_t
    public let title: String
    public let frame: CGRect

    public init(id: WindowID, ownerPID: pid_t, title: String, frame: CGRect) {
        self.id = id
        self.ownerPID = ownerPID
        self.title = title
        self.frame = frame
    }
}

public struct WindowInventoryReadBatch: Equatable, Sendable {
    public let records: [WindowInventoryRecord]
    public let errors: [AXWindowReadError]

    public init(records: [WindowInventoryRecord], errors: [AXWindowReadError]) {
        self.records = records
        self.errors = errors
    }
}

public struct WindowInventoryFilter: Sendable {
    public let currentProcessID: pid_t

    public init(currentProcessID: pid_t) {
        self.currentProcessID = currentProcessID
    }

    public func accepts(layer: Int, ownerPID: pid_t, frame: CGRect) -> Bool {
        layer == 0
            && ownerPID != currentProcessID
            && frame.width > 0
            && frame.height > 0
    }

    public func read(_ windows: [[String: Any]]) -> WindowInventoryReadBatch {
        var records: [WindowInventoryRecord] = []
        var errors: [AXWindowReadError] = []
        for window in windows {
            switch read(window) {
            case .record(let record):
                records.append(record)
            case .ignored:
                break
            case .failure(let error):
                errors.append(error)
            }
        }
        return WindowInventoryReadBatch(records: records, errors: errors)
    }

    private func read(_ window: [String: Any]) -> WindowInventoryRead {
        let candidateID = windowID(window[kCGWindowNumber as String])
        let candidatePID = processID(window[kCGWindowOwnerPID as String])

        guard let layer = integer(window[kCGWindowLayer as String]) else {
            return .failure(readError(candidateID, candidatePID, "missing or invalid window layer"))
        }
        guard layer == 0 else { return .ignored }

        guard let ownerPID = candidatePID, ownerPID > 0 else {
            return .failure(readError(candidateID, candidatePID, "missing or invalid owner process ID"))
        }
        guard ownerPID != currentProcessID else { return .ignored }

        guard let id = candidateID else {
            return .failure(readError(nil, ownerPID, "missing or invalid window number"))
        }
        guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: boundsDictionary),
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite
        else {
            return .failure(readError(id, ownerPID, "missing or invalid window bounds"))
        }
        guard frame.width > 0, frame.height > 0 else { return .ignored }

        return .record(WindowInventoryRecord(
            id: id,
            ownerPID: ownerPID,
            title: window[kCGWindowName as String] as? String ?? "",
            frame: frame
        ))
    }

    private func readError(_ id: WindowID?, _ pid: pid_t?, _ message: String) -> AXWindowReadError {
        AXWindowReadError(windowID: id, pid: pid, message: message)
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private func processID(_ value: Any?) -> pid_t? {
        guard let number = value as? NSNumber else { return value as? pid_t }
        let raw = number.int64Value
        guard raw >= Int64(pid_t.min), raw <= Int64(pid_t.max) else { return nil }
        return pid_t(raw)
    }

    private func windowID(_ value: Any?) -> WindowID? {
        if let value = value as? CGWindowID, value > 0 {
            return WindowID(raw: value)
        }
        guard let number = value as? NSNumber else { return nil }
        let raw = number.int64Value
        guard raw > 0, raw <= Int64(CGWindowID.max) else { return nil }
        return WindowID(raw: CGWindowID(raw))
    }
}

private enum WindowInventoryRead {
    case record(WindowInventoryRecord)
    case ignored
    case failure(AXWindowReadError)
}
