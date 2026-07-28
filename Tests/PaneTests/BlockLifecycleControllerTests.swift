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
    func testRestartInterruptsRunningAndQueuedBlocksAndRetainsSanitizedReplay() throws {
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
                rows: 30
            ),
            runningID
        )

        let running = try XCTUnwrap(controller.timeline.block(id: runningID))
        let queued = try XCTUnwrap(controller.timeline.block(id: queuedID))
        XCTAssertEqual(running.state, .interrupted(exitCode: nil))
        XCTAssertEqual(queued.state, .interrupted(exitCode: nil))
        XCTAssertNotNil(running.terminalSnapshot)
        XCTAssertNil(queued.terminalSnapshot)
        XCTAssertNil(controller.activeOrAwaitingBlockID)
        controller.assertInvariants()
    }
}
