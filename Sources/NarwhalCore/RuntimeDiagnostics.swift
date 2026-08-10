public enum RuntimeMetricKind: String, Codable, CaseIterable, Equatable, Sendable {
    case windowSnapshot = "window_snapshot"
    case focusedWindowSnapshot = "focused_window_snapshot"
    case layoutPlan = "layout_plan"
    case coordinatedFrameWrite = "coordinated_frame_write"
    case manualResizeHandoff = "manual_resize_handoff"
    case layoutTransaction = "layout_transaction"
    case layoutRollback = "layout_rollback"
    case workspaceReconciliation = "workspace_reconciliation"
    case restoreWrite = "restore_write"
}

public struct RuntimeMetricSummary: Codable, Equatable, Sendable {
    public let metric: RuntimeMetricKind
    public let sampleCount: UInt64
    public let retainedSampleCount: Int
    public let latestMilliseconds: Double
    public let medianMilliseconds: Double
    public let p95Milliseconds: Double
    public let maximumMilliseconds: Double

    public init(
        metric: RuntimeMetricKind,
        sampleCount: UInt64,
        retainedSampleCount: Int,
        latestMilliseconds: Double,
        medianMilliseconds: Double,
        p95Milliseconds: Double,
        maximumMilliseconds: Double
    ) {
        self.metric = metric
        self.sampleCount = sampleCount
        self.retainedSampleCount = retainedSampleCount
        self.latestMilliseconds = latestMilliseconds
        self.medianMilliseconds = medianMilliseconds
        self.p95Milliseconds = p95Milliseconds
        self.maximumMilliseconds = maximumMilliseconds
    }
}

public enum RuntimeSnapshotQuality: String, Codable, Equatable, Sendable {
    case complete
    case partial
    case permissionDenied = "permission_denied"
    case unavailable
    case unknown
}

public struct RuntimeDiagnostics: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: String
    public let appVersion: String
    public let buildVersion: String
    public let accessibilityTrusted: Bool
    public let notificationFastPathActive: Bool
    public let configHealthy: Bool
    public let paused: Bool
    public let activeSpaceID: UInt64?
    public let displayCount: Int
    public let windowCount: Int
    public let tiledWindowCount: Int
    public let snapshotQuality: RuntimeSnapshotQuality
    public let focusedWindowID: UInt32?
    public let lastCommand: String?
    public let pendingHotkeyCount: Int
    public let pendingGeometryEventCount: Int
    public let droppedLogLineCount: UInt64
    public let latency: [RuntimeMetricSummary]

    public init(
        schemaVersion: Int = RuntimeDiagnostics.currentSchemaVersion,
        generatedAt: String,
        appVersion: String,
        buildVersion: String,
        accessibilityTrusted: Bool,
        notificationFastPathActive: Bool,
        configHealthy: Bool,
        paused: Bool,
        activeSpaceID: UInt64?,
        displayCount: Int,
        windowCount: Int,
        tiledWindowCount: Int,
        snapshotQuality: RuntimeSnapshotQuality,
        focusedWindowID: UInt32?,
        lastCommand: String?,
        pendingHotkeyCount: Int,
        pendingGeometryEventCount: Int,
        droppedLogLineCount: UInt64,
        latency: [RuntimeMetricSummary]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.accessibilityTrusted = accessibilityTrusted
        self.notificationFastPathActive = notificationFastPathActive
        self.configHealthy = configHealthy
        self.paused = paused
        self.activeSpaceID = activeSpaceID
        self.displayCount = displayCount
        self.windowCount = windowCount
        self.tiledWindowCount = tiledWindowCount
        self.snapshotQuality = snapshotQuality
        self.focusedWindowID = focusedWindowID
        self.lastCommand = lastCommand
        self.pendingHotkeyCount = pendingHotkeyCount
        self.pendingGeometryEventCount = pendingGeometryEventCount
        self.droppedLogLineCount = droppedLogLineCount
        self.latency = latency
    }
}
