import Foundation

actor ExecutableIndex {
    struct Snapshot: Sendable {
        let pathValue: String
        let executableNames: [String]
    }

    private struct Cache: Sendable {
        let pathValue: String
        let shellGeneration: UInt64
        let createdAt: Date
        let executableNames: [String]
    }

    private let ttl: TimeInterval
    private var cache: Cache?

    init(ttl: TimeInterval = 60) {
        self.ttl = max(1, ttl)
    }

    func candidates(
        prefix: String,
        path: String,
        currentDirectory: URL,
        shellGeneration: UInt64
    ) async -> [String] {
        let components = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let absolutePath = components.filter { $0.hasPrefix("/") }.joined(separator: ":")
        let absoluteNames: [String]
        if let cache,
           cache.pathValue == absolutePath,
           cache.shellGeneration == shellGeneration,
           Date().timeIntervalSince(cache.createdAt) < ttl {
            absoluteNames = cache.executableNames
        } else {
            absoluteNames = scan(components.filter { $0.hasPrefix("/") }, relativeTo: currentDirectory)
            cache = Cache(pathValue: absolutePath, shellGeneration: shellGeneration, createdAt: Date(), executableNames: absoluteNames)
        }

        guard !Task.isCancelled else { return [] }
        // Empty and relative PATH entries are cwd-dependent and deliberately
        // stay outside the reusable absolute index.
        let relativeNames = scan(components.filter { !$0.hasPrefix("/") }, relativeTo: currentDirectory)
        return Set(absoluteNames.lazy.filter { $0.hasPrefix(prefix) })
            .union(relativeNames.lazy.filter { $0.hasPrefix(prefix) })
            .sorted()
    }

    func refresh() {
        cache = nil
    }

    private func scan(_ components: [String], relativeTo cwd: URL) -> [String] {
        var names = Set<String>()
        for component in components {
            guard !Task.isCancelled else { break }
            let directory = component.isEmpty
                ? cwd
                : (component.hasPrefix("/")
                    ? URL(fileURLWithPath: component, isDirectory: true)
                    : cwd.appendingPathComponent(component, isDirectory: true))
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in entries {
                let url = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      FileManager.default.isExecutableFile(atPath: url.path) else { continue }
                names.insert(name)
            }
        }
        return names.sorted()
    }
}
