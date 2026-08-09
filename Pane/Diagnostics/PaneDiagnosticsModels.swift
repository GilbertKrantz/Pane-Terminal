import Foundation

struct PaneSoakSample: Codable, Equatable, Sendable {
    let timestamp: Date
    let residentMemoryBytes: UInt64
    let virtualMemoryBytes: UInt64
    let threadCount: Int
    let fileDescriptorCount: Int
    let liveSessionCount: Int
    let livePTYCount: Int
    let completionTaskCount: Int
    let blockCount: Int
    let idleCPUPercent: Double
}

/// Sanitized session state suitable for diagnostic export. Deliberately absent
/// are command text, output, environment values, remote URLs, and drafts.
struct TerminalSessionDiagnostics: Codable, Equatable, Sendable {
    let tabID: UUID
    let sessionID: UUID
    let ptyGeneration: UInt64
    let interactionState: String
    let focusTarget: String
    let visibilityState: String
    let shellReadiness: String
    let foregroundProcessName: String?
    let activeBlockID: UUID?
    let isAlternateScreenActive: Bool
    let isSecureInputActive: Bool
    let completionGeneration: UInt64
    let contextRefreshStatus: String
    let blockCount: Int
    let estimatedRetainedOutputBytes: Int
    let terminalMount: TerminalMountDiagnostics
}

struct TerminalMountDiagnostics: Codable, Equatable, Sendable {
    let expectedPlacement: String
    let leaseID: UUID?
    let mountID: String?
    let hostParentID: String?
    let hasWindow: Bool
    let isUnderExpectedMount: Bool
    let width: Double
    let height: Double
    let terminalColumns: Int
    let terminalRows: Int
    let ptyRunning: Bool
    let claimCount: Int
    let releaseCount: Int
    let staleUpdateRejectionCount: Int
    let validationFailureCount: Int
    let automaticRepairCount: Int
    let successfulRepairCount: Int
    let terminalIdentityChangeCount: Int
    let ptyGenerationChangeCount: Int
    let lastMountAt: Date?
    let lastDetachAt: Date?
    let lastFailedValidationAt: Date?
    let lastRepairAttemptAt: Date?
    let lastRepairResultAt: Date?
}

struct PaneWorkspaceDiagnostics: Codable, Equatable, Sendable {
    let lifecycleState: String
    let selectedTabID: UUID?
    let tabCount: Int
}

struct PaneDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let workspace: PaneWorkspaceDiagnostics
    let sessions: [TerminalSessionDiagnostics]
    let resourceCounters: PaneResourceSnapshot
    let processMetrics: PaneProcessMetricsSnapshot
    let persistenceStatus: PersistenceDiagnostic
    let lifecycleEvents: [PaneLifecycleEvent]
    let appVersion: String
    let macOSVersion: String
    let timestamp: Date

    func encodedJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum PaneLifecycleEventKind: String, Codable, Sendable {
    case sessionCreated
    case sessionSelected
    case sessionClosing
    case sessionClosed
    case shellStarted
    case shellRestarted
    case ptyStarted
    case ptyStopped
    case persistenceRead
    case persistenceWrite
    case recovery
    case resourceWarning
}

enum PaneLifecycleEventOutcome: String, Codable, Sendable {
    case requested
    case succeeded
    case failed
    case timedOut
    case interrupted
    case fallbackUsed
}

struct PaneLifecycleEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let kind: PaneLifecycleEventKind
    let tabID: UUID?
    let sessionID: UUID?
    let outcome: PaneLifecycleEventOutcome?
}

/// Workspace-wide sanitized lifecycle history. Its fixed capacity prevents a
/// diagnostic facility from becoming a long-session memory leak itself.
actor PaneLifecycleEventRing {
    static let shared = PaneLifecycleEventRing()

    let capacity: Int
    private var events: [PaneLifecycleEvent] = []
    private var nextInsertionIndex = 0

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
        events.reserveCapacity(self.capacity)
    }

    func append(_ event: PaneLifecycleEvent) {
        if events.count < capacity {
            events.append(event)
            return
        }
        events[nextInsertionIndex] = event
        nextInsertionIndex = (nextInsertionIndex + 1) % capacity
    }

    func snapshot() -> [PaneLifecycleEvent] {
        guard events.count == capacity, nextInsertionIndex != 0 else {
            return events
        }
        return Array(events[nextInsertionIndex...]) + Array(events[..<nextInsertionIndex])
    }

    func removeAll() {
        events.removeAll(keepingCapacity: true)
        nextInsertionIndex = 0
    }
}
