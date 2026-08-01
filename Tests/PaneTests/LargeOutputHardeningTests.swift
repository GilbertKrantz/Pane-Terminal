import Foundation
import XCTest
@testable import Pane

final class LargeOutputHardeningTests: XCTestCase {
    @MainActor
    func testCompletedOutputUsesBoundedUTF8SafeHeadTailExcerpt() throws {
        let controller = BlockLifecycleController()
        let id = controller.queue(
            command: "pane-fixture large-output",
            workingDirectory: "/tmp",
            isRerunnable: true
        )
        controller.markAwaitingStart(id)
        XCTAssertEqual(controller.commandStarted(), id)

        let output = "HEAD\n"
            + String(repeating: "e\u{301}🙂漢字", count: 80_000)
            + "\nTAIL"
        controller.consumeTerminalBytes(Data(output.utf8))
        XCTAssertEqual(
            controller.completeActive(
                exitCode: 0,
                // The mounted terminal's scrollback can be a much smaller
                // viewport than the full stream and must not be called complete.
                renderedOutput: "VISIBLE TAIL ONLY",
                columns: 80,
                rows: 24
            ),
            id
        )

        let block = try XCTUnwrap(controller.timeline.block(id: id))
        XCTAssertEqual(block.outputKind, .excerpt)
        XCTAssertLessThanOrEqual(
            block.output.utf8.count,
            ScrollbackPolicy.standard.excerptByteLimit
        )
        XCTAssertTrue(block.output.hasPrefix("HEAD"))
        XCTAssertTrue(block.output.hasSuffix("TAIL"))
        XCTAssertTrue(block.output.contains("[Pane omitted "))
        XCTAssertEqual(
            block.output.components(separatedBy: "[Pane omitted ").count,
            2
        )
        XCTAssertFalse(block.output.contains("\u{FFFD}"))
        XCTAssertNotNil(block.output.data(using: .utf8))
    }

    @MainActor
    func testRichReplayAndPlainOutputShareOneBoundedCapture() throws {
        let controller = BlockLifecycleController()
        let id = controller.queue(
            command: "pane-fixture ansi",
            workingDirectory: "/tmp",
            isRerunnable: true
        )
        controller.markAwaitingStart(id)
        XCTAssertEqual(controller.commandStarted(), id)

        var bytes = Data("\u{001B}[31mHEAD\u{001B}[0m".utf8)
        bytes.append(Data(repeating: UInt8(ascii: "x"), count: 600_000))
        bytes.append(Data("TAIL".utf8))
        controller.consumeTerminalBytes(bytes)
        XCTAssertLessThanOrEqual(
            controller.capturedOutputData.count,
            ScrollbackPolicy.standard.excerptByteLimit
        )

        _ = controller.completeActive(
            exitCode: 0,
            renderedOutput: nil,
            columns: 120,
            rows: 40
        )

        let block = try XCTUnwrap(controller.timeline.block(id: id))
        let replay = try XCTUnwrap(block.terminalSnapshot)
        XCTAssertLessThanOrEqual(
            replay.bytes.count,
            ScrollbackPolicy.standard.excerptByteLimit
        )
        XCTAssertTrue(replay.isTruncated)
        XCTAssertEqual(block.outputKind, .excerpt)
    }

    func testPolicyPrunesOldestFinalizedBlocksButNeverRunningOrQueued() throws {
        let policy = ScrollbackPolicy(
            terminalLineLimit: 10_000,
            finalizedBlockLimit: 2,
            retainedOutputByteLimit: 1_024 * 1_024,
            excerptByteLimit: 256 * 1_024
        )
        var timeline = CommandBlockTimeline()
        var finalizedIDs: [UUID] = []
        for index in 0..<4 {
            let id = timeline.enqueue(
                command: "echo \(index)",
                workingDirectory: "/tmp"
            )
            finalizedIDs.append(id)
            XCTAssertEqual(timeline.beginNext(), id)
            timeline.finishActive(exitCode: 0, output: "done \(index)")
        }
        let runningID = timeline.enqueue(command: "sleep 30", workingDirectory: "/tmp")
        XCTAssertEqual(timeline.beginNext(), runningID)
        let queuedID = timeline.enqueue(command: "echo queued", workingDirectory: "/tmp")

        let notice = try XCTUnwrap(timeline.enforceScrollbackPolicy(policy))

        XCTAssertEqual(notice.removedBlockIDs, Array(finalizedIDs.prefix(2)))
        XCTAssertEqual(notice.removedBlockCount, 2)
        XCTAssertEqual(timeline.blocks.map(\.id), [
            finalizedIDs[2], finalizedIDs[3], runningID, queuedID
        ])
        XCTAssertEqual(timeline.activeBlockID, runningID)
        XCTAssertEqual(
            notice.replacementSelection(for: finalizedIDs[0]),
            finalizedIDs[2]
        )
        XCTAssertEqual(
            notice.replacementSelection(for: runningID),
            runningID
        )
    }

    func testPolicyPrunesByCombinedOutputAndReplayBytesDeterministically() throws {
        let policy = ScrollbackPolicy(
            terminalLineLimit: 10_000,
            finalizedBlockLimit: 100,
            retainedOutputByteLimit: 700,
            excerptByteLimit: 256
        )
        var timeline = CommandBlockTimeline()
        var ids: [UUID] = []
        for index in 0..<4 {
            let id = timeline.enqueue(command: "command-\(index)", workingDirectory: "/tmp")
            ids.append(id)
            XCTAssertEqual(timeline.beginNext(), id)
            timeline.finishActive(
                exitCode: 0,
                output: String(repeating: "\(index)", count: 400),
                terminalSnapshot: TerminalReplaySnapshot(
                    bytes: Data(repeating: UInt8(index), count: 100),
                    columns: 80,
                    rows: 24,
                    isTruncated: false
                )
            )
        }

        let notice = try XCTUnwrap(timeline.enforceScrollbackPolicy(policy))

        XCTAssertEqual(notice.removedBlockIDs, Array(ids.prefix(3)))
        XCTAssertEqual(timeline.blocks.map(\.id), [ids[3]])
        XCTAssertLessThanOrEqual(timeline.retainedOutputByteCount, 700)
        XCTAssertEqual(timeline.blocks[0].outputKind, .excerpt)
    }

    @MainActor
    func testLifecyclePublishesSessionLevelPruningNotice() throws {
        let policy = ScrollbackPolicy(
            terminalLineLimit: 10_000,
            finalizedBlockLimit: 1,
            retainedOutputByteLimit: 1_024,
            excerptByteLimit: 512
        )
        let controller = BlockLifecycleController(scrollbackPolicy: policy)
        var callbackNotice: ScrollbackPruningNotice?
        controller.onTimelinePruned = { callbackNotice = $0 }

        for index in 0..<2 {
            let id = controller.queue(
                command: "echo \(index)",
                workingDirectory: "/tmp",
                isRerunnable: true
            )
            controller.markAwaitingStart(id)
            XCTAssertEqual(controller.commandStarted(), id)
            controller.consumeTerminalBytes(Data("\(index)\n".utf8))
            _ = controller.completeActive(
                exitCode: 0,
                renderedOutput: nil,
                columns: 80,
                rows: 24
            )
        }

        let notice = try XCTUnwrap(controller.pruningNotice)
        XCTAssertEqual(notice.removedBlockCount, 1)
        XCTAssertEqual(callbackNotice, notice)
        XCTAssertTrue(notice.message.contains("older block"))
        controller.dismissPruningNotice()
        XCTAssertNil(controller.pruningNotice)
    }

    func testIndexedSearchRejectsStaleDebouncedGeneration() async throws {
        let first = CommandBlock(
            command: "swift test",
            workingDirectory: "/tmp/Pane",
            state: .completed(exitCode: 0),
            output: "All tests passed"
        )
        let second = CommandBlock(
            command: "npm test",
            workingDirectory: "/tmp/Web",
            state: .completed(exitCode: 1),
            output: "Assertion failed"
        )
        let index = BlockSearchIndex()
        await index.replace(blocks: [first, second])

        let stale = Task {
            await index.search(
                BlockSearchQuery(text: "swift", filter: .commands),
                debounce: .milliseconds(50)
            )
        }
        try await Task.sleep(for: .milliseconds(5))
        let current = await index.search(
            BlockSearchQuery(text: "assertion", filter: .output),
            debounce: .zero
        )
        let staleResult = await stale.value
        let currentGeneration = await index.currentGeneration()

        XCTAssertNil(staleResult)
        XCTAssertEqual(current?.blockIDs, [second.id])
        XCTAssertEqual(current?.generation, currentGeneration)
    }

    func testIndexedSearchHandlesTenThousandBlocksAtSessionScope() async {
        let targetID = UUID()
        let blocks = (0..<10_000).map { index in
            CommandBlock(
                id: index == 9_999 ? targetID : UUID(),
                command: index == 9_999 ? "needle-command" : "echo \(index)",
                workingDirectory: "/tmp",
                state: .completed(exitCode: 0),
                output: "bounded excerpt \(index)"
            )
        }
        let searchIndex = BlockSearchIndex()
        await searchIndex.replace(blocks: blocks)

        let result = await searchIndex.search(
            BlockSearchQuery(text: "needle-command", filter: .commands),
            debounce: .zero
        )

        XCTAssertEqual(result?.blockIDs, [targetID])
    }
}
