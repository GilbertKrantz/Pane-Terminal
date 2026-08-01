import AppKit
import Darwin
import XCTest
@preconcurrency import SwiftTerm
@testable import Pane

final class ResourceLifecycleHardeningTests: XCTestCase {
    @MainActor
    func testShortCreateCloseCycleConvergesResourcesAndDescriptors() async {
#if DEBUG
        await runLifecycleCycles(count: 20)
#endif
    }

    @MainActor
    func testHundredCreateCloseCyclesWhenNightlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PANE_RUN_RESOURCE_STRESS"] == "1" else {
            throw XCTSkip("Nightly resource suite sets PANE_RUN_RESOURCE_STRESS=1")
        }
#if DEBUG
        try await runRealPTYLifecycleCycles(count: 100)
#endif
    }

    func testHundredGitContextRefreshesConvergeProcessesAndDescriptors() async throws {
#if DEBUG
        let root = try makeTemporaryGitRoot()
        try initializeGitRepository(at: root)
        let provider = ProjectContextProvider()
        let warmMetrics = PaneProcessMetrics.snapshot()
        let warmChildProcesses = childProcessCount()

        for iteration in 0..<100 {
            let context = await provider.gitContext(root: root)
            XCTAssertNotNil(context, "Git refresh \(iteration) failed")
            XCTAssertEqual(context?.remoteNames, [])
        }

        await assertProcessResourcesConverge(
            descriptors: warmMetrics.fileDescriptorCount,
            children: warmChildProcesses
        )
#endif
    }

    func testGitLaunchFailureClosesPipeWithoutCreatingChild() async throws {
#if DEBUG
        let root = try makeTemporaryGitRoot()
        let warmMetrics = PaneProcessMetrics.snapshot()
        let warmChildProcesses = childProcessCount()
        let provider = ProjectContextProvider(
            gitExecutableURL: root.appendingPathComponent("missing-git"),
            gitArgumentPrefix: []
        )

        let context = await provider.gitContext(root: root)

        XCTAssertNil(context)
        await assertProcessResourcesConverge(
            descriptors: warmMetrics.fileDescriptorCount,
            children: warmChildProcesses
        )
#endif
    }

    func testGitTimeoutAndCancellationKillChildAndClosePipe() async throws {
#if DEBUG
        let root = try makeTemporaryGitRoot()
        let provider = slowGitProvider()

        var warmMetrics = PaneProcessMetrics.snapshot()
        var warmChildProcesses = childProcessCount()
        let timeoutStartedAt = ContinuousClock.now
        let timedOutContext = await provider.gitContext(root: root)
        XCTAssertNil(timedOutContext)
        XCTAssertLessThan(
            timeoutStartedAt.duration(to: .now),
            .seconds(2)
        )
        await assertProcessResourcesConverge(
            descriptors: warmMetrics.fileDescriptorCount,
            children: warmChildProcesses
        )

        warmMetrics = PaneProcessMetrics.snapshot()
        warmChildProcesses = childProcessCount()
        let cancellationStartedAt = ContinuousClock.now
        let task = Task { await provider.gitContext(root: root) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let cancelledContext = await task.value
        XCTAssertNil(cancelledContext)
        XCTAssertLessThan(
            cancellationStartedAt.duration(to: .now),
            .seconds(2)
        )
        await assertProcessResourcesConverge(
            descriptors: warmMetrics.fileDescriptorCount,
            children: warmChildProcesses
        )
#endif
    }

#if DEBUG
    private func makeTemporaryGitRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Pane-GitLifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func initializeGitRepository(at root: URL) throws {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--quiet", root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func slowGitProvider() -> ProjectContextProvider {
        ProjectContextProvider(
            gitExecutableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            gitArgumentPrefix: [
                "-c",
                "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
            ]
        )
    }

    private func assertProcessResourcesConverge(
        descriptors: Int,
        children: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now.advanced(
            by: PanePerformanceThresholds.resourceConvergenceTimeout
        )
        while ContinuousClock.now < deadline {
            let metrics = PaneProcessMetrics.snapshot()
            if childProcessCount() <= children,
               metrics.fileDescriptorCount <= descriptors {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertLessThanOrEqual(
            childProcessCount(),
            children,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            PaneProcessMetrics.snapshot().fileDescriptorCount,
            descriptors + PanePerformanceThresholds.maximumDescriptorResidualFloor,
            file: file,
            line: line
        )
    }

    @MainActor
    private func runLifecycleCycles(
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let warmResources = PaneResourceCounters.snapshot
        let warmMetrics = PaneProcessMetrics.snapshot()
        let warmDescriptors = warmMetrics.fileDescriptorCount

        for _ in 0..<count {
            await createAndCloseOneSession()
        }

        let deadline = ContinuousClock.now.advanced(
            by: PanePerformanceThresholds.resourceConvergenceTimeout
        )
        while PaneResourceCounters.snapshot != warmResources,
              ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        let finalResources = PaneResourceCounters.snapshot
        let finalDescriptors = PaneProcessMetrics.snapshot().fileDescriptorCount
        let allowedDescriptorResidual = max(
            PanePerformanceThresholds.maximumDescriptorResidualFloor,
            Int(
                ceil(
                    Double(max(1, warmDescriptors))
                        * PanePerformanceThresholds.maximumDescriptorResidualFraction
                )
            )
        )
        XCTAssertEqual(finalResources, warmResources, file: file, line: line)
        XCTAssertLessThanOrEqual(
            finalDescriptors - warmDescriptors,
            allowedDescriptorResidual,
            file: file,
            line: line
        )
        if count >= 100 {
            let memoryResidual = max(
                0,
                Int64(PaneProcessMetrics.snapshot().residentMemoryBytes)
                    - Int64(warmMetrics.residentMemoryBytes)
            )
            XCTAssertLessThanOrEqual(
                Double(memoryResidual),
                Double(max(1, warmMetrics.residentMemoryBytes))
                    * PanePerformanceThresholds.maximumMemoryResidualFraction,
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func createAndCloseOneSession() async {
        let controller = PTYController(
            terminationDelay: .nanoseconds(0),
            processFactory: { _ in ResourceFakePTYDriver() }
        )
        let session = TerminalSession(
            commandHistoryEnabled: false,
            ptyController: controller
        )
        let terminalView = PaneTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320)
        )
        session.attach(terminalView: terminalView)
        _ = await session.shutdownAndWait()
        session.detach(terminalView: terminalView)
    }

    @MainActor
    private func runRealPTYLifecycleCycles(
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let warmResources = PaneResourceCounters.snapshot
        let warmMetrics = PaneProcessMetrics.snapshot()
        let warmChildProcesses = childProcessCount()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Pane-RealPTYLifecycle-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        for index in 0..<count {
            let home = temporaryRoot.appendingPathComponent(
                "session-\(index)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: home,
                withIntermediateDirectories: true
            )
            let configuration = ShellConfiguration.loginZsh(
                processEnvironment: [
                    "HOME": home.path,
                    "ZDOTDIR": home.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                ],
                homeDirectory: home
            )
            let session = TerminalSession(
                shellConfiguration: configuration,
                commandHistoryEnabled: false
            )
            let terminalView = PaneTerminalView(
                frame: NSRect(x: 0, y: 0, width: 640, height: 320)
            )
            session.attach(terminalView: terminalView)
            let readinessDeadline = ContinuousClock.now.advanced(
                by: .seconds(5)
            )
            while !session.isShellReadyForInput,
                  ContinuousClock.now < readinessDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(
                session.isShellReadyForInput,
                "cycle \(index) shell did not become ready",
                file: file,
                line: line
            )
            let result = await session.shutdownAndWait()
            XCTAssertNotEqual(
                result.processTermination.outcome,
                .timedOut,
                "cycle \(index) PTY cleanup timed out",
                file: file,
                line: line
            )
            session.detach(terminalView: terminalView)
            try? FileManager.default.removeItem(at: home)
        }

        let convergenceDeadline = ContinuousClock.now.advanced(
            by: PanePerformanceThresholds.resourceConvergenceTimeout
        )
        while PaneResourceCounters.snapshot != warmResources,
              ContinuousClock.now < convergenceDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let finalResources = PaneResourceCounters.snapshot
        let finalMetrics = PaneProcessMetrics.snapshot()
        let finalChildProcesses = childProcessCount()
        let allowedDescriptorResidual = max(
            PanePerformanceThresholds.maximumDescriptorResidualFloor,
            Int(
                ceil(
                    Double(max(1, warmMetrics.fileDescriptorCount))
                        * PanePerformanceThresholds.maximumDescriptorResidualFraction
                )
            )
        )

        XCTAssertEqual(finalResources, warmResources, file: file, line: line)
        XCTAssertLessThanOrEqual(
            finalChildProcesses,
            warmChildProcesses,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            finalMetrics.fileDescriptorCount - warmMetrics.fileDescriptorCount,
            allowedDescriptorResidual,
            file: file,
            line: line
        )
        if ProcessInfo.processInfo.environment[
            "PANE_REFERENCE_RESOURCE_GATES"
        ] == "1" {
            let residual = max(
                0,
                Int64(finalMetrics.residentMemoryBytes)
                    - Int64(warmMetrics.residentMemoryBytes)
            )
            XCTAssertLessThanOrEqual(
                Double(residual),
                Double(max(1, warmMetrics.residentMemoryBytes))
                    * PanePerformanceThresholds.maximumMemoryResidualFraction,
                file: file,
                line: line
            )
        }
        print(
            "Pane real PTY stress count=\(count) "
                + "children=\(warmChildProcesses)->\(finalChildProcesses) "
                + "fds=\(warmMetrics.fileDescriptorCount)->\(finalMetrics.fileDescriptorCount) "
                + "threads=\(warmMetrics.threadCount)->\(finalMetrics.threadCount) "
                + "rss=\(warmMetrics.residentMemoryBytes)->\(finalMetrics.residentMemoryBytes) "
                + "resources=\(warmResources)->\(finalResources)"
        )
    }

    private func childProcessCount() -> Int {
        let capacity = Int(max(0, proc_listchildpids(getpid(), nil, 0)))
        guard capacity > 0 else { return 0 }
        var processIDs = Array(repeating: pid_t(0), count: capacity)
        return processIDs.withUnsafeMutableBytes { buffer in
            Int(max(0, proc_listchildpids(
                getpid(),
                buffer.baseAddress,
                Int32(buffer.count)
            )))
        }
    }
#endif
}

@MainActor
private final class ResourceFakePTYDriver: PTYProcessDriving {
    private(set) var running = false
    let childFileDescriptor: Int32 = -1
    let shellProcessID: pid_t = 0
    func start(
        configuration: ShellConfiguration,
        workingDirectory: String
    ) {
        running = true
    }

    func send(_ data: ArraySlice<UInt8>) {}

    func terminate() {
        running = false
    }
}
