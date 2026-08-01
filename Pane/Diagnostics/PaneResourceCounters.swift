import Foundation

struct PaneResourceSnapshot: Codable, Equatable, Sendable {
    let liveSessions: Int
    let liveTerminalViews: Int
    let livePTYControllers: Int
    let livePTYs: Int
    let liveCompletionServices: Int
    let completionTaskCount: Int
    let liveContextRefreshTasks: Int

    static let zero = PaneResourceSnapshot(
        liveSessions: 0,
        liveTerminalViews: 0,
        livePTYControllers: 0,
        livePTYs: 0,
        liveCompletionServices: 0,
        completionTaskCount: 0,
        liveContextRefreshTasks: 0
    )
}

enum PaneResourceKind: CaseIterable, Sendable {
    case session
    case terminalView
    case ptyController
    case runningPTY
    case completionService
    case completionTask
    case contextRefreshTask
}

/// Debug-only lifecycle accounting. The backing storage is lock protected so
/// callers may record creation and cleanup from actors, AppKit callbacks, or
/// process queues without hopping to the main actor.
enum PaneResourceCounters {
    private static let storage = PaneResourceCounterStorage()

    static func increment(_ resource: PaneResourceKind) {
#if DEBUG
        storage.increment(resource)
#endif
    }

    static func decrement(_ resource: PaneResourceKind) {
#if DEBUG
        storage.decrement(resource)
#endif
    }

    static var snapshot: PaneResourceSnapshot {
#if DEBUG
        storage.snapshot
#else
        .zero
#endif
    }

    static var liveSessions: Int { snapshot.liveSessions }
    static var liveTerminalViews: Int { snapshot.liveTerminalViews }
    static var livePTYControllers: Int { snapshot.livePTYControllers }
    static var livePTYs: Int { snapshot.livePTYs }
    static var liveCompletionServices: Int { snapshot.liveCompletionServices }
    static var completionTaskCount: Int { snapshot.completionTaskCount }
    static var liveContextRefreshTasks: Int { snapshot.liveContextRefreshTasks }

#if DEBUG
    static func resetForTesting() {
        storage.reset()
    }
#endif
}

private final class PaneResourceCounterStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PaneResourceKind: Int] = [:]

    func increment(_ resource: PaneResourceKind) {
        lock.withLock {
            values[resource, default: 0] += 1
        }
    }

    func decrement(_ resource: PaneResourceKind) {
        lock.withLock {
            let current = values[resource, default: 0]
            assert(current > 0, "Unbalanced Pane resource counter: \(resource)")
            values[resource] = max(0, current - 1)
        }
    }

    var snapshot: PaneResourceSnapshot {
        lock.withLock {
            PaneResourceSnapshot(
                liveSessions: values[.session, default: 0],
                liveTerminalViews: values[.terminalView, default: 0],
                livePTYControllers: values[.ptyController, default: 0],
                livePTYs: values[.runningPTY, default: 0],
                liveCompletionServices: values[.completionService, default: 0],
                completionTaskCount: values[.completionTask, default: 0],
                liveContextRefreshTasks: values[.contextRefreshTask, default: 0]
            )
        }
    }

    func reset() {
        lock.withLock {
            values.removeAll(keepingCapacity: true)
        }
    }
}

private extension NSLock {
    func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try operation()
    }
}
