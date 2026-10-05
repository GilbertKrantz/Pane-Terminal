import Foundation
import os

enum PanePerformanceSignposts {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "app.pane",
        category: .pointsOfInterest
    )

    static func beginTabSwitch() -> OSSignpostID {
        begin(name: "TabSwitch")
    }

    static func endTabSwitch(_ id: OSSignpostID) {
        end(name: "TabSwitch", id: id)
    }

    static func beginBlockFinalization() -> OSSignpostID {
        begin(name: "BlockFinalization")
    }

    static func endBlockFinalization(_ id: OSSignpostID) {
        end(name: "BlockFinalization", id: id)
    }

    static func beginWorkspacePersistence() -> OSSignpostID {
        begin(name: "WorkspacePersistence")
    }

    static func endWorkspacePersistence(_ id: OSSignpostID) {
        end(name: "WorkspacePersistence", id: id)
    }

    static func beginTabDisplay() -> OSSignpostID { begin(name: "TabDisplaySubmitted") }
    static func endTabDisplay(_ id: OSSignpostID, completed: Bool = true) {
        os_signpost(.end, log: log, name: "TabDisplaySubmitted", signpostID: id,
                    "completed=%{public}d", completed ? 1 : 0)
    }
    static func beginBlockDisplay() -> OSSignpostID { begin(name: "BlockDisplaySubmitted") }
    static func endBlockDisplay(_ id: OSSignpostID, completed: Bool = true) {
        os_signpost(.end, log: log, name: "BlockDisplaySubmitted", signpostID: id,
                    "completed=%{public}d", completed ? 1 : 0)
    }

    private static func begin(name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    private static func end(name: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}

struct PanePresentationTimingSnapshot: Codable, Equatable, Sendable {
    let tabDisplaySubmittedMilliseconds: [Double]
    let blockDisplaySubmittedMilliseconds: [Double]
}

/// Display submission includes layout and the native drawing turn. It is
/// deliberately distinct from WindowServer/GPU presentation or frame latency.
@MainActor
final class PanePresentationTimings {
    private var tab: OSSignpostID?
    private var block: (UUID, OSSignpostID)?
    private(set) var tabDisplaySamplesMilliseconds: [Double] = []
    private(set) var blockDisplaySamplesMilliseconds: [Double] = []
    private var tabStarted: ContinuousClock.Instant?
    private var blockStarted: ContinuousClock.Instant?

    func beginTabDisplay() {
        if let tab { PanePerformanceSignposts.endTabDisplay(tab, completed: false) }
        tab = PanePerformanceSignposts.beginTabDisplay()
        tabStarted = .now
    }

    func beginBlockDisplay(id: UUID) {
        if let block { PanePerformanceSignposts.endBlockDisplay(block.1, completed: false) }
        block = (id, PanePerformanceSignposts.beginBlockDisplay())
        blockStarted = .now
    }

    func didSubmitDisplay(visibleBlocks: Set<UUID>) {
        if let tab {
            PanePerformanceSignposts.endTabDisplay(tab)
            record(tabStarted, in: &tabDisplaySamplesMilliseconds)
            self.tab = nil
            tabStarted = nil
        }
        if let block, visibleBlocks.contains(block.0) {
            PanePerformanceSignposts.endBlockDisplay(block.1)
            record(blockStarted, in: &blockDisplaySamplesMilliseconds)
            self.block = nil
            blockStarted = nil
        }
    }

    func cancel() {
        if let tab { PanePerformanceSignposts.endTabDisplay(tab, completed: false) }
        tab = nil; tabStarted = nil
        cancelBlockDisplay()
    }

    func cancelBlockDisplay() {
        if let block { PanePerformanceSignposts.endBlockDisplay(block.1, completed: false) }
        block = nil; blockStarted = nil
    }

    func snapshot() -> PanePresentationTimingSnapshot {
        PanePresentationTimingSnapshot(tabDisplaySubmittedMilliseconds: tabDisplaySamplesMilliseconds,
                                       blockDisplaySubmittedMilliseconds: blockDisplaySamplesMilliseconds)
    }

    private func record(_ start: ContinuousClock.Instant?, in samples: inout [Double]) {
        guard let start else { return }
        let duration = start.duration(to: .now).components
        samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        if samples.count > 256 { samples.removeFirst(samples.count - 256) }
    }
}
