import XCTest
@testable import Pane

final class BlockLifecycleControllerTests: XCTestCase {
    @MainActor
    func testQueueStartAndCompletionHaveOneAuthoritativeLifecycle() throws {
        let controller = BlockLifecycleController()
        var published: [CommandBlockTimeline] = []
        controller.onTimelineChanged = { published.append($0) }

        let id = controller.queue(
            command: "printf hello",
            workingDirectory: "/tmp",
            isRerunnable: true
        )
        controller.markAwaitingStart(id)
        XCTAssertEqual(controller.activeOrAwaitingBlockID, id)
        XCTAssertEqual(controller.commandStarted(), id)
        XCTAssertNil(controller.awaitingStartID)

        controller.consumeTerminalBytes(Data("hello\n".utf8))
        XCTAssertEqual(
            controller.completeActive(
                exitCode: 0,
                renderedOutput: nil,
                columns: 80,
                rows: 25
            ),
            id
        )

        let block = try XCTUnwrap(controller.timeline.block(id: id))
        XCTAssertEqual(block.state, .completed(exitCode: 0))
        XCTAssertEqual(block.output, "hello")
        XCTAssertNil(block.terminalSnapshot)
        XCTAssertNil(controller.activeOrAwaitingBlockID)
        XCTAssertGreaterThanOrEqual(published.count, 3)
        controller.assertInvariants()
    }

    @MainActor
    func testSecondCommandCannotStartWhileAnotherBlockIsRunning() {
        let controller = BlockLifecycleController()
        let first = controller.queue(
            command: "sleep 1",
            workingDirectory: "/tmp",
            isRerunnable: true
        )
        _ = controller.queue(
            command: "echo later",
            workingDirectory: "/tmp",
            isRerunnable: true
        )
        controller.markAwaitingStart(first)

        XCTAssertEqual(controller.commandStarted(), first)
        XCTAssertNil(controller.commandStarted())
        XCTAssertEqual(controller.timeline.activeBlockID, first)
        controller.assertInvariants()
    }

    @MainActor
    func testQueuedCommandsSupportFIFORemovalAndReordering() {
        let controller = BlockLifecycleController()
        let first = controller.queue(command: "one", workingDirectory: "/tmp", isRerunnable: true)
        let second = controller.queue(command: "two", workingDirectory: "/tmp", isRerunnable: true)
        let third = controller.queue(command: "three", workingDirectory: "/tmp", isRerunnable: true)

        XCTAssertEqual(controller.queuedBlocks.map(\.id), [first, second, third])
        XCTAssertEqual(controller.firstQueuedBlock()?.id, first)
        XCTAssertTrue(controller.moveQueued(id: third, before: first))
        XCTAssertEqual(controller.queuedBlocks.map(\.id), [third, first, second])
        XCTAssertTrue(controller.removeQueued(id: first))
        XCTAssertEqual(controller.queuedBlocks.map(\.id), [third, second])
    }

    @MainActor
    func testQueueAPIsRejectAwaitingAndRunningBlocks() {
        let controller = BlockLifecycleController()
        let first = controller.queue(command: "one", workingDirectory: "/tmp", isRerunnable: true)
        let second = controller.queue(command: "two", workingDirectory: "/tmp", isRerunnable: true)
        controller.markAwaitingStart(first)

        XCTAssertFalse(controller.removeQueued(id: first))
        XCTAssertFalse(controller.moveQueued(id: first, before: second))
        XCTAssertEqual(controller.commandStarted(), first)
        XCTAssertFalse(controller.removeQueued(id: first))
        XCTAssertEqual(controller.firstQueuedBlock()?.id, second)
    }

    @MainActor
    func testRestartInterruptsRunningBlockButPreservesQueuedBlocks() throws {
        let controller = BlockLifecycleController()
        let runningID = controller.queue(
            command: "interactive",
            workingDirectory: "/tmp",
            isRerunnable: true
        )
        let queuedID = controller.queue(
            command: "echo queued",
            workingDirectory: "/tmp",
            isRerunnable: true
        )
        controller.markAwaitingStart(runningID)
        XCTAssertEqual(controller.commandStarted(), runningID)
        controller.consumeTerminalBytes(Data("\u{001B}[31mred\u{001B}[0m".utf8))
        controller.markDirectInteraction()

        XCTAssertEqual(
            controller.interruptUnfinished(
                exitCode: nil,
                renderedOutput: nil,
                columns: 100,
                rows: 30,
                preserveQueued: true
            ),
            runningID
        )

        let running = try XCTUnwrap(controller.timeline.block(id: runningID))
        let queued = try XCTUnwrap(controller.timeline.block(id: queuedID))
        XCTAssertEqual(running.state, .interrupted(exitCode: nil))
        XCTAssertEqual(queued.state, .queued)
        XCTAssertNotNil(running.terminalSnapshot)
        XCTAssertNil(queued.terminalSnapshot)
        XCTAssertNil(controller.activeOrAwaitingBlockID)
        XCTAssertEqual(controller.firstQueuedBlock()?.id, queuedID)
        controller.assertInvariants()
    }
}
