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

#if DEBUG
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
