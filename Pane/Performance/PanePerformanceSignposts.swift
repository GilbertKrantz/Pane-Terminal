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

    private static func begin(name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    private static func end(name: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}
