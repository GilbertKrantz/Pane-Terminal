import Foundation
import XCTest
@testable import Pane

final class CommandBlockTimelineTests: XCTestCase {
    func testQueuedCommandAcceptsContinuationAndCanBeInterrupted() throws {
        var timeline = CommandBlockTimeline()
        let id = timeline.enqueue(command: "if true; then", workingDirectory: "/tmp")

        XCTAssertEqual(
            timeline.appendContinuation("echo yes", to: id),
            "if true; then\necho yes"
        )
        timeline.interruptQueued(id: id, exitCode: 130)

        let block = try XCTUnwrap(timeline.block(id: id))
        XCTAssertEqual(block.command, "if true; then\necho yes")
        XCTAssertEqual(block.state, .interrupted(exitCode: 130))
        XCTAssertNil(timeline.beginNext())
    }

    func testClearFinalizedPreservesRunningAndQueuedCommands() throws {
        var timeline = CommandBlockTimeline()

        _ = timeline.enqueue(command: "finished", workingDirectory: "/tmp")
        _ = try XCTUnwrap(timeline.beginNext())
        _ = timeline.finishActive(exitCode: 0, output: "done")

        let runningID = timeline.enqueue(command: "running", workingDirectory: "/tmp")
        XCTAssertEqual(timeline.beginNext(), runningID)
        let queuedID = timeline.enqueue(command: "queued", workingDirectory: "/tmp")

        timeline.clearFinalized()

        XCTAssertEqual(timeline.blocks.map(\.id), [runningID, queuedID])
        XCTAssertEqual(timeline.activeBlockID, runningID)
        XCTAssertNotNil(timeline.block(id: queuedID))
    }

    func testQueuedCommandBecomesRunningAndCompletes() throws {
        var timeline = CommandBlockTimeline()
        let submitted = Date(timeIntervalSince1970: 10)
        let started = Date(timeIntervalSince1970: 11)
        let completed = Date(timeIntervalSince1970: 12.25)

        let id = timeline.enqueue(command: "npm test", workingDirectory: "/tmp", at: submitted)
        XCTAssertEqual(timeline.beginNext(at: started), id)

        XCTAssertEqual(
            timeline.finishActive(
                exitCode: 0,
                output: "13 tests passed",
                at: completed
            ),
            id
        )

        let block = try XCTUnwrap(timeline.block(id: id))
        XCTAssertEqual(block.output, "13 tests passed")
        XCTAssertEqual(try XCTUnwrap(block.duration), 1.25, accuracy: 0.001)
        XCTAssertEqual(block.statusText, "1.2 s")
        XCTAssertTrue(block.succeeded)
    }

    func testCommandsStartInSubmissionOrder() {
        var timeline = CommandBlockTimeline()
        let first = timeline.enqueue(command: "pwd", workingDirectory: "/")
        let second = timeline.enqueue(command: "git status", workingDirectory: "/")

        XCTAssertEqual(timeline.beginNext(), first)
        timeline.finishActive(exitCode: 0)
        XCTAssertEqual(timeline.beginNext(), second)
    }

    func testInterruptUnfinishedLeavesCompletedBlocksUntouched() throws {
        var timeline = CommandBlockTimeline()
        let completedID = timeline.enqueue(command: "true", workingDirectory: "/")
        timeline.beginNext()
        timeline.finishActive(exitCode: 0)
        let queuedID = timeline.enqueue(command: "sleep 5", workingDirectory: "/")

        timeline.interruptUnfinished(
            exitCode: 143,
            activeOutput: "partial output"
        )

        let completed = try XCTUnwrap(timeline.block(id: completedID))
        let interrupted = try XCTUnwrap(timeline.block(id: queuedID))
        XCTAssertTrue(completed.succeeded)
        XCTAssertEqual(interrupted.state, .interrupted(exitCode: 143))
    }

    func testFinalOutputIsCommittedOnlyWhenTheActiveCommandFinishes() throws {
        var timeline = CommandBlockTimeline()
        let id = timeline.enqueue(command: "brew upgrade", workingDirectory: "/tmp")
        timeline.beginNext()

        XCTAssertEqual(try XCTUnwrap(timeline.block(id: id)).output, "")

        timeline.finishActive(exitCode: 0, output: "Downloaded\nInstalled")

        let completed = try XCTUnwrap(timeline.block(id: id))
        XCTAssertEqual(completed.output, "Downloaded\nInstalled")
        XCTAssertEqual(completed.state, .completed(exitCode: 0))
    }

    func testSearchMatchesCommandOutputDirectoryAndFailureState() {
        let successful = CommandBlock(
            command: "swift test",
            workingDirectory: "/tmp/Pane",
            state: .completed(exitCode: 0),
            output: "All tests passed"
        )
        let failed = CommandBlock(
            command: "npm test",
            workingDirectory: "/tmp/Web",
            state: .completed(exitCode: 1),
            output: "Assertion failed"
        )

        XCTAssertTrue(BlockSearchQuery(text: "tests passed").matches(successful))
        XCTAssertTrue(BlockSearchQuery(text: "pane").matches(successful))
        XCTAssertTrue(BlockSearchQuery(text: "", filter: .failed).matches(failed))
        XCTAssertFalse(BlockSearchQuery(text: "", filter: .failed).matches(successful))
    }

    func testRestoredCollapsedStateIsPreserved() throws {
        var timeline = CommandBlockTimeline()
        let restored = CommandBlock(
            command: "pwd",
            workingDirectory: "/tmp",
            state: .completed(exitCode: 0),
            isCollapsed: true
        )
        timeline.restore([restored])
        XCTAssertTrue(try XCTUnwrap(timeline.block(id: restored.id)).isCollapsed)
    }
}
