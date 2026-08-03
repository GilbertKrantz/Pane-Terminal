import Darwin
import Foundation

struct FixtureTimeouts: Sendable {
    let startup: TimeInterval
    let readiness: TimeInterval
    let action: TimeInterval
    let cleanup: TimeInterval
    let total: TimeInterval

    static let standard = FixtureTimeouts(
        startup: 5,
        readiness: 5,
        action: 5,
        cleanup: 2,
        total: 20
    )
}

struct FixtureRunResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let duration: TimeInterval

    var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

struct FixtureExecutionError: Error, CustomStringConvertible {
    enum Stage: String {
        case startup
        case readiness
        case action
        case cleanup
        case total
    }

    let stage: Stage
    let mode: String
    let diagnostic: String

    var description: String {
        "fixture=\(mode) stage=\(stage.rawValue) \(diagnostic)"
    }
}

final class FixtureProcessRunner {
    static let readyMarker = Data("PANE_FIXTURE_READY".utf8)

    private let fixtureURL: URL
    private let timeouts: FixtureTimeouts
    private let pythonExecutableURL: URL
    private let environment: [String: String]

    init(
        fixtureURL: URL,
        timeouts: FixtureTimeouts = .standard
    ) throws {
        self.fixtureURL = fixtureURL
        self.timeouts = timeouts
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        pythonExecutableURL = try Self.resolvePythonExecutable(
            environment: inheritedEnvironment
        )
        environment = Self.fixtureEnvironment(from: inheritedEnvironment)
    }

    func run(
        _ mode: String,
        arguments: [String] = [],
        inputAfterReady: Data? = nil,
        signalAfterReady: Int32? = nil
    ) throws -> FixtureRunResult {
        let startedAt = Date()
        let totalDeadline = startedAt.addingTimeInterval(timeouts.total)
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        let output = LockedDataBuffer()
        let errors = LockedDataBuffer()

        process.executableURL = pythonExecutableURL
        process.arguments = [fixtureURL.path, mode] + arguments
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                output.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errors.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            stopReading(outputPipe, errorPipe)
            throw FixtureExecutionError(
                stage: .startup,
                mode: mode,
                diagnostic: String(describing: error)
            )
        }

        guard Date().timeIntervalSince(startedAt) <= timeouts.startup else {
            try terminate(
                process,
                mode: mode,
                outputPipe: outputPipe,
                errorPipe: errorPipe
            )
            throw FixtureExecutionError(
                stage: .startup,
                mode: mode,
                diagnostic: "Process.run exceeded startup deadline"
            )
        }

        let readinessDeadline = min(
            Date().addingTimeInterval(timeouts.readiness),
            totalDeadline
        )
        while !output.contains(Self.readyMarker),
              process.isRunning,
              Date() < readinessDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard output.contains(Self.readyMarker) else {
            let stage: FixtureExecutionError.Stage =
                Date() >= totalDeadline ? .total : .readiness
            try terminate(
                process,
                mode: mode,
                outputPipe: outputPipe,
                errorPipe: errorPipe
            )
            throw FixtureExecutionError(
                stage: stage,
                mode: mode,
                diagnostic: "ready marker missing; stderr=\(errors.string)"
            )
        }

        if let signalAfterReady {
            _ = Darwin.kill(process.processIdentifier, signalAfterReady)
        }
        if let inputAfterReady {
            try inputPipe.fileHandleForWriting.write(contentsOf: inputAfterReady)
        }
        try? inputPipe.fileHandleForWriting.close()

        let actionDeadline = min(
            Date().addingTimeInterval(timeouts.action),
            totalDeadline
        )
        while process.isRunning, Date() < actionDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            let stage: FixtureExecutionError.Stage =
                Date() >= totalDeadline ? .total : .action
            try terminate(
                process,
                mode: mode,
                outputPipe: outputPipe,
                errorPipe: errorPipe
            )
            throw FixtureExecutionError(
                stage: stage,
                mode: mode,
                diagnostic: "process did not exit after fixture action"
            )
        }

        process.waitUntilExit()
        drainAndStop(outputPipe, into: output)
        drainAndStop(errorPipe, into: errors)
        return FixtureRunResult(
            status: process.terminationStatus,
            stdout: output.snapshot,
            stderr: errors.snapshot,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    private func terminate(
        _ process: Process,
        mode: String,
        outputPipe: Pipe,
        errorPipe: Pipe
    ) throws {
        if process.isRunning {
            process.terminate()
        }
        let cleanupDeadline = Date().addingTimeInterval(timeouts.cleanup)
        let terminateDeadline = Date().addingTimeInterval(
            min(1, timeouts.cleanup / 2)
        )
        while process.isRunning,
              Date() < terminateDeadline,
              Date() < cleanupDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        while process.isRunning, Date() < cleanupDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        stopReading(outputPipe, errorPipe)
        guard !process.isRunning else {
            throw FixtureExecutionError(
                stage: .cleanup,
                mode: mode,
                diagnostic: "child survived SIGTERM and SIGKILL"
            )
        }
        process.waitUntilExit()
    }

    private func drainAndStop(
        _ pipe: Pipe,
        into buffer: LockedDataBuffer
    ) {
        pipe.fileHandleForReading.readabilityHandler = nil
        let remainder = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remainder.isEmpty {
            buffer.append(remainder)
        }
    }

    private func stopReading(_ outputPipe: Pipe, _ errorPipe: Pipe) {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
    }

    private static func resolvePythonExecutable(
        environment: [String: String]
    ) throws -> URL {
        if let configuredPath = environment["PANE_FIXTURE_PYTHON"],
           !configuredPath.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: configuredPath) else {
                throw FixtureExecutionError(
                    stage: .startup,
                    mode: "fixture",
                    diagnostic: "PANE_FIXTURE_PYTHON is not executable: \(configuredPath)"
                )
            }
            return URL(fileURLWithPath: configuredPath)
        }

        let fallbackPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        guard let path = fallbackPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw FixtureExecutionError(
                stage: .startup,
                mode: "fixture",
                diagnostic: "No executable Python 3 interpreter was found"
            )
        }
        return URL(fileURLWithPath: path)
    }

    private static func fixtureEnvironment(
        from inheritedEnvironment: [String: String]
    ) -> [String: String] {
        var environment = inheritedEnvironment
        [
            "DEVELOPER_DIR",
            "SDKROOT",
            "TOOLCHAINS",
            "DYLD_FRAMEWORK_PATH",
            "DYLD_LIBRARY_PATH",
            "DYLD_FALLBACK_FRAMEWORK_PATH",
        ].forEach { environment.removeValue(forKey: $0) }
        return environment
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ value: Data) {
        lock.lock()
        data.append(value)
        lock.unlock()
    }

    func contains(_ value: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.range(of: value) != nil
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    var string: String {
        String(decoding: snapshot, as: UTF8.self)
    }
}
