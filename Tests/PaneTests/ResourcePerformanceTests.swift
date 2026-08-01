import XCTest
@testable import Pane

final class ResourcePerformanceTests: XCTestCase {
    func testResourceCountersAreBalancedAndSnapshotIsCodable() throws {
#if DEBUG
        let baseline = PaneResourceCounters.snapshot
        PaneResourceCounters.increment(.terminalView)
        PaneResourceCounters.increment(.runningPTY)

        let active = PaneResourceCounters.snapshot
        XCTAssertEqual(active.liveTerminalViews, baseline.liveTerminalViews + 1)
        XCTAssertEqual(active.livePTYs, baseline.livePTYs + 1)

        PaneResourceCounters.decrement(.terminalView)
        PaneResourceCounters.decrement(.runningPTY)
        XCTAssertEqual(PaneResourceCounters.snapshot, baseline)

        let data = try JSONEncoder().encode(active)
        XCTAssertEqual(try JSONDecoder().decode(PaneResourceSnapshot.self, from: data), active)
#endif
    }

    func testLifecycleEventRingRetainsNewestEventsInOrder() async {
        let ring = PaneLifecycleEventRing(capacity: 3)
        let base = Date(timeIntervalSince1970: 1_000)

        for offset in 0..<5 {
            await ring.append(PaneLifecycleEvent(
                timestamp: base.addingTimeInterval(Double(offset)),
                kind: .sessionSelected,
                tabID: nil,
                sessionID: nil,
                outcome: offset.isMultiple(of: 2) ? .requested : .succeeded
            ))
        }

        let events = await ring.snapshot()
        XCTAssertEqual(
            events.map(\.timestamp),
            [2, 3, 4].map { base.addingTimeInterval(Double($0)) }
        )
    }

    func testGitCacheUsesVisibilitySpecificTTL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = GitContextCache()
        let loads = ResourceTestCounter()
        let base = Date(timeIntervalSince1970: 10_000)
        let loader: @Sendable () async -> GitContext? = {
            let count = await loads.increment()
            return GitContext(
                root: root,
                branch: "branch-\(count)",
                headOID: nil,
                isDirty: false,
                hasStagedChanges: false,
                remoteNames: []
            )
        }

        let initial = await cache.value(
            for: root,
            ttl: PanePerformanceThresholds.inactiveGitTTL,
            now: base,
            loader: loader
        )
        let stillFreshWhileInactive = await cache.value(
            for: root,
            ttl: PanePerformanceThresholds.inactiveGitTTL,
            now: base.addingTimeInterval(20),
            loader: loader
        )
        let refreshedWhenSelected = await cache.value(
            for: root,
            ttl: PanePerformanceThresholds.selectedGitTTL,
            now: base.addingTimeInterval(20),
            loader: loader
        )

        XCTAssertEqual(initial?.branch, "branch-1")
        XCTAssertEqual(stillFreshWhileInactive?.branch, "branch-1")
        XCTAssertEqual(refreshedWhenSelected?.branch, "branch-2")
    }

    func testPerformanceThresholdsMatchP2ReleaseGuardrails() {
        XCTAssertEqual(PanePerformanceThresholds.projectDefinitionTTL, 300)
        XCTAssertEqual(PanePerformanceThresholds.selectedGitTTL, 10)
        XCTAssertEqual(PanePerformanceThresholds.inactiveGitTTL, 45)
        XCTAssertEqual(PanePerformanceThresholds.typicalTabSwitchMilliseconds, 50)
        XCTAssertEqual(PanePerformanceThresholds.typicalBlockPublicationMilliseconds, 16)
        XCTAssertEqual(PanePerformanceThresholds.maximumMemoryResidualFraction, 0.15)
    }

    func testCompletionCancellationWaitsForTrackedTaskCleanup() async {
#if DEBUG
        let baseline = PaneResourceCounters.snapshot.completionTaskCount
        let service = CompletionService()
        let request = CompletionRequest(
            id: UUID(),
            generation: 1,
            draft: "git",
            cursorUTF16Offset: 3,
            tokenContext: CommandTokenContext(
                replacementRange: NSRange(location: 0, length: 3),
                decodedPrefix: "git",
                isCommandPosition: true
            ),
            currentDirectory: FileManager.default.temporaryDirectory,
            projectContext: nil,
            previousCommand: nil,
            executableSearchPath: "",
            shellGeneration: 1,
            maximumResults: 12,
            createdAt: ContinuousClock.now
        )
        let stream = await service.responses(
            for: request,
            providers: [ResourceSlowCompletionProvider()],
            budgets: [.local: .seconds(30)]
        )
        let consumer = Task {
            for await _ in stream {}
        }

        for _ in 0..<100 {
            if PaneResourceCounters.snapshot.completionTaskCount != baseline {
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(
            PaneResourceCounters.snapshot.completionTaskCount,
            baseline + 1
        )

        await service.cancelPendingRequests()
        await consumer.value
        XCTAssertEqual(PaneResourceCounters.snapshot.completionTaskCount, baseline)
#endif
    }

    func testProcessMetricsAndSoakSamplingAreBoundedAndPopulated() async {
        let metrics = PaneProcessMetrics.snapshot()
        XCTAssertGreaterThan(metrics.residentMemoryBytes, 0)
        XCTAssertGreaterThan(metrics.virtualMemoryBytes, 0)
        XCTAssertGreaterThan(metrics.threadCount, 0)
        XCTAssertGreaterThan(metrics.fileDescriptorCount, 0)
        XCTAssertGreaterThanOrEqual(metrics.cumulativeCPUSeconds, 0)

        let sampler = PaneProcessMetricSampler()
        _ = await sampler.sample(blockCount: 12)
        try? await Task.sleep(for: .milliseconds(5))
        let sample = await sampler.sample(blockCount: 12)
        XCTAssertEqual(sample.blockCount, 12)
        XCTAssertGreaterThan(sample.residentMemoryBytes, 0)
        XCTAssertGreaterThanOrEqual(sample.idleCPUPercent, 0)
    }
}

private actor ResourceTestCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}

private struct ResourceSlowCompletionProvider: CompletionProvider {
    let identifier: CompletionProviderID = .local

    func candidates(for request: CompletionRequest) async throws -> [CompletionCandidate] {
        try await Task.sleep(for: .seconds(30))
        return []
    }
}
