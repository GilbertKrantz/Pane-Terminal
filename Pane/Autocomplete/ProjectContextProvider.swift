import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = maximumBytes - data.count
        guard remaining > 0 else { return }
        data.append(incoming.prefix(remaining))
    }

    /// Drains one readability notification. An empty read is EOF, so the
    /// handler must be removed or Foundation will continuously redeliver the
    /// readable EOF and consume a CPU core.
    @discardableResult
    func drainAvailableData(from handle: FileHandle) -> Bool {
        let incoming = handle.availableData
        guard !incoming.isEmpty else {
            handle.readabilityHandler = nil
            return false
        }
        append(incoming)
        return true
    }

    func string() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)
    }
}

private final class ProcessOutputDrainState: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false

    func markFinished() {
        lock.lock()
        didFinish = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinish
    }
}

private final class ProcessTerminationState: @unchecked Sendable {
    private let lock = NSLock()
    private var didTerminate = false

    func markTerminated() {
        lock.lock()
        didTerminate = true
        lock.unlock()
    }

    var isTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTerminate
    }
}

enum ProjectKind: String, Sendable { case git, node, swift, xcode, python, rust, go, make, just, mixed }
enum ProjectLanguage: String, Hashable, Sendable { case swift, javaScript, python, rust, go }

struct ProjectManifest: Equatable, Sendable {
    let url: URL
    let modificationDate: Date?
}

struct ProjectScript: Equatable, Sendable {
    let name: String
    let command: String
    let manifestURL: URL
}

struct GitContext: Equatable, Sendable {
    let root: URL
    let branch: String?
    let headOID: String?
    let isDirty: Bool
    let hasStagedChanges: Bool
    let remoteNames: [String]
}

struct ProjectContext: Equatable, Sendable {
    let root: URL
    let identity: String
    let kind: ProjectKind
    let git: GitContext?
    let manifests: [ProjectManifest]
    let scripts: [ProjectScript]
    let detectedLanguages: Set<ProjectLanguage>
    let discoveredAt: Date
}

actor ProjectDefinitionCache {
    private struct Entry { let context: ProjectContext?; let createdAt: Date }
    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval
    init(ttl: TimeInterval = 300) { self.ttl = max(1, ttl) }

    func value(
        for directory: URL,
        now: Date = Date(),
        loader: @Sendable () async -> ProjectContext?
    ) async -> ProjectContext? {
        let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
        if let entry = entries[key], now.timeIntervalSince(entry.createdAt) < ttl,
           Self.manifestsAreCurrent(entry.context) { return entry.context }
        let context = await loader()
        entries[key] = Entry(context: context, createdAt: now)
        return context
    }
    func invalidate() { entries.removeAll() }
    private static func manifestsAreCurrent(_ context: ProjectContext?) -> Bool {
        guard let context else { return true }
        return context.manifests.allSatisfy {
            let attributes = try? FileManager.default.attributesOfItem(atPath: $0.url.path)
            return attributes?[.modificationDate] as? Date == $0.modificationDate
        }
    }
}

actor GitContextCache {
    private struct Entry { let context: GitContext?; let createdAt: Date }
    private var entries: [String: Entry] = [:]
    private let defaultTTL: TimeInterval

    init(activeTTL: TimeInterval = 5) {
        self.defaultTTL = max(1, activeTTL)
    }

    func value(
        for root: URL,
        ttl: TimeInterval? = nil,
        now: Date = Date(),
        loader: @Sendable () async -> GitContext?
    ) async -> GitContext? {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        let effectiveTTL = max(1, ttl ?? defaultTTL)
        if let entry = entries[key],
           now.timeIntervalSince(entry.createdAt) < effectiveTTL {
            return entry.context
        }
        let context = await loader()
        entries[key] = Entry(context: context, createdAt: now)
        return context
    }

    func invalidate(root: URL? = nil) {
        guard let root else {
            entries.removeAll()
            return
        }
        entries.removeValue(
            forKey: root.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }
}

/// Bounded, read-only project discovery. It never runs project code and Git is
/// queried with prompts disabled and a small wall-clock timeout.
struct ProjectContextProvider: Sendable {
    let maximumParentDepth: Int
    private let gitExecutableURL: URL
    private let gitArgumentPrefix: [String]

    init(
        maximumParentDepth: Int = 12,
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        gitArgumentPrefix: [String] = ["git"]
    ) {
        self.maximumParentDepth = max(0, maximumParentDepth)
        self.gitExecutableURL = gitExecutableURL
        self.gitArgumentPrefix = gitArgumentPrefix
    }

    func context(for directory: URL) async -> ProjectContext? {
        guard let definition = definition(for: directory) else { return nil }
        let git = await gitContext(root: definition.root)
        return ProjectContext(
            root: definition.root,
            identity: definition.identity,
            kind: definition.kind,
            git: git,
            manifests: definition.manifests,
            scripts: definition.scripts,
            detectedLanguages: definition.detectedLanguages,
            discoveredAt: definition.discoveredAt
        )
    }

    func definition(for directory: URL) -> ProjectContext? {
        guard let root = detectRoot(from: directory) else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let manifests = manifestNames(in: files).map { name -> ProjectManifest in
            let url = root.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let date = attributes?[.modificationDate] as? Date
            return ProjectManifest(url: url, modificationDate: date)
        }
        let scripts = projectScripts(root: root, files: files)
        let languages = detectedLanguages(files: files)
        let kind = projectKind(files: files, languages: languages)
        return ProjectContext(root: root, identity: stableIdentity(root), kind: kind, git: nil,
            manifests: manifests, scripts: scripts, detectedLanguages: languages, discoveredAt: Date())
    }

    func detectRoot(from directory: URL) -> URL? {
        var current = directory.standardizedFileURL.resolvingSymlinksInPath()
        for _ in 0...maximumParentDepth {
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? [])
            if names.contains(where: isMarker) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private func isMarker(_ name: String) -> Bool {
        let fixed: Set<String> = [".git", "Package.swift", "package.json", "pnpm-workspace.yaml", "yarn.lock", "package-lock.json", "pyproject.toml", "requirements.txt", "Cargo.toml", "go.mod", "Makefile", "justfile"]
        return fixed.contains(name) || name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
    }
    private func manifestNames(in files: [String]) -> [String] { files.filter(isMarker).sorted() }
    private func detectedLanguages(files: [String]) -> Set<ProjectLanguage> {
        var result: Set<ProjectLanguage> = []
        if files.contains("Package.swift") || files.contains(where: { $0.hasSuffix(".xcodeproj") }) { result.insert(.swift) }
        if files.contains("package.json") { result.insert(.javaScript) }
        if files.contains("pyproject.toml") || files.contains("requirements.txt") { result.insert(.python) }
        if files.contains("Cargo.toml") { result.insert(.rust) }
        if files.contains("go.mod") { result.insert(.go) }
        return result
    }
    private func projectKind(files: [String], languages: Set<ProjectLanguage>) -> ProjectKind {
        if languages.count > 1 { return .mixed }
        if languages.contains(.javaScript) { return .node }; if languages.contains(.swift) { return files.contains("Package.swift") ? .swift : .xcode }
        if languages.contains(.python) { return .python }; if languages.contains(.rust) { return .rust }; if languages.contains(.go) { return .go }
        if files.contains("justfile") { return .just }; if files.contains("Makefile") { return .make }; return .git
    }
    private func projectScripts(root: URL, files: [String]) -> [ProjectScript] {
        var commands: [(String, String, String)] = []
        if files.contains("package.json"), let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let scripts = json["scripts"] as? [String: Any] {
            let manager = files.contains("pnpm-lock.yaml") ? "pnpm" : files.contains("yarn.lock") ? "yarn" : (files.contains("bun.lock") || files.contains("bun.lockb")) ? "bun" : "npm"
            commands += scripts.keys.sorted().map { ($0, manager == "npm" ? "npm run \($0)" : "\(manager) \($0)", "package.json") }
        }
        if files.contains("Package.swift") { commands += [("build", "swift build", "Package.swift"), ("test", "swift test", "Package.swift"), ("run", "swift run", "Package.swift")] }
        if files.contains("Cargo.toml") { commands += ["build", "test", "run", "check"].map { ($0, "cargo \($0)", "Cargo.toml") } }
        if files.contains("go.mod") { commands += [("build", "go build ./...", "go.mod"), ("test", "go test ./...", "go.mod"), ("run", "go run .", "go.mod")] }
        if files.contains("pyproject.toml") || files.contains("requirements.txt") { let m = files.contains("pyproject.toml") ? "pyproject.toml" : "requirements.txt"; commands += [("test", "pytest", m), ("module-test", "python -m pytest", m), ("venv", "python -m venv .venv", m)] }
        if files.contains("Makefile") {
            commands += recipeNames(
                at: root.appendingPathComponent("Makefile"),
                syntax: .make
            ).map { ($0, "make \($0)", "Makefile") }
        }
        if files.contains("justfile") {
            commands += recipeNames(
                at: root.appendingPathComponent("justfile"),
                syntax: .just
            ).map { ($0, "just \($0)", "justfile") }
        }
        var seen: Set<String> = []
        return commands.compactMap {
            guard seen.insert($0.1).inserted else { return nil }
            return ProjectScript(
                name: $0.0,
                command: $0.1,
                manifestURL: root.appendingPathComponent($0.2)
            )
        }
    }

    private enum RecipeSyntax { case make, just }

    private func recipeNames(at url: URL, syntax: RecipeSyntax) -> [String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var names: [String] = []
        var seen: Set<String> = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(10_000) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(".") else { continue }
            let name: String?
            switch syntax {
            case .make:
                guard rawLine.first != "\t",
                      let colon = line.firstIndex(of: ":"),
                      !line[..<colon].contains("=") else {
                    continue
                }
                name = line[..<colon].split(whereSeparator: \.isWhitespace).first.map(String.init)
            case .just:
                guard !line.hasPrefix("@"),
                      let colon = line.firstIndex(of: ":"),
                      !line[..<colon].contains("=") else {
                    continue
                }
                name = line[..<colon].split(whereSeparator: \.isWhitespace).first.map(String.init)
            }
            guard let name,
                  name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
                  seen.insert(name).inserted else {
                continue
            }
            names.append(name)
            if names.count == 100 { break }
        }
        return names.sorted()
    }
    private func stableIdentity(_ root: URL) -> String {
        // Stable local FNV-1a hash; unlike Hashable it is reproducible across launches.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in root.standardizedFileURL.resolvingSymlinksInPath().path.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
    func gitContext(root: URL) async -> GitContext? {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return nil }
        guard let output = await runGit(["status", "--porcelain=v1", "--branch"], at: root) else { return nil }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let branchLine = lines.first(where: { $0.hasPrefix("## ") })
        let branch = branchName(from: branchLine)
        let changes = lines.filter { !$0.hasPrefix("## ") && !$0.isEmpty }
        let staged = changes.contains { line in line.first.map { $0 != " " && $0 != "?" } ?? false }
        async let oidOutput = runGit(["rev-parse", "HEAD"], at: root)
        async let remoteOutput = runGit(["remote"], at: root)
        let (rawOID, rawRemotes) = await (oidOutput, remoteOutput)
        let oid = rawOID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let remotes = rawRemotes?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .sorted() ?? []
        return GitContext(
            root: root,
            branch: branch,
            headOID: oid?.isEmpty == false ? oid : nil,
            isDirty: !changes.isEmpty,
            hasStagedChanges: staged,
            remoteNames: remotes
        )
    }

    private func branchName(from statusHeader: String?) -> String? {
        guard var value = statusHeader.map({ String($0.dropFirst(3)) }),
              value != "HEAD (no branch)" else {
            return nil
        }
        if value.hasPrefix("No commits yet on ") {
            value.removeFirst("No commits yet on ".count)
        } else if value.hasPrefix("Initial commit on ") {
            value.removeFirst("Initial commit on ".count)
        }
        if let tracking = value.range(of: "...") {
            value = String(value[..<tracking.lowerBound])
        } else if let suffix = value.firstIndex(of: " ") {
            value = String(value[..<suffix])
        }
        return value.isEmpty ? nil : value
    }
    private func runGit(_ arguments: [String], at directory: URL) async -> String? {
        let process = Process()
        let pipe = Pipe()
        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
        let output = BoundedProcessOutput(maximumBytes: 1_048_576)
        let drainState = ProcessOutputDrainState()
        let terminationState = ProcessTerminationState()
        DispatchQueue.global(qos: .utility).async {
            defer { drainState.markFinished() }
            while true {
                do {
                    guard let chunk = try readHandle.read(upToCount: 16_384),
                          !chunk.isEmpty else {
                        return
                    }
                    output.append(chunk)
                } catch {
                    return
                }
            }
        }
        process.executableURL = gitExecutableURL
        process.arguments = gitArgumentPrefix + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            terminationState.markTerminated()
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        func finishDraining() async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .milliseconds(250))
            while !drainState.isFinished,
                  clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }

            // A descendant holding stdout open must never retain the pipe or
            // its background reader after the bounded process lifetime.
            if !drainState.isFinished {
                try? readHandle.close()
                let forcedDeadline = clock.now.advanced(by: .milliseconds(50))
                while !drainState.isFinished,
                      clock.now < forcedDeadline {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            try? readHandle.close()
        }

        do {
            try process.run()
        } catch {
            try? writeHandle.close()
            try? readHandle.close()
            await finishDraining()
            return nil
        }
        // Process has duplicated the descriptor. Keeping the parent's writer
        // open prevents EOF and can retain the readability callback forever.
        try? writeHandle.close()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        while process.isRunning, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = clock.now.advanced(by: .milliseconds(50))
            while process.isRunning, clock.now < terminationDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            let killDeadline = clock.now.advanced(by: .milliseconds(250))
            while process.isRunning, clock.now < killDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        // `Process.isRunning` becomes false when the child exits, but its
        // reaping callback can arrive later. Retain the Process and wait for
        // that callback before returning so repeated cancellation cannot leave
        // a short-lived zombie owned by the app.
        let reapDeadline = clock.now.advanced(by: .milliseconds(250))
        while !terminationState.isTerminated,
              clock.now < reapDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let didExit = !process.isRunning && terminationState.isTerminated
        try? writeHandle.close()
        await finishDraining()
        guard didExit,
              drainState.isFinished,
              !Task.isCancelled,
              process.terminationStatus == 0 else { return nil }
        return output.string()
    }
}
