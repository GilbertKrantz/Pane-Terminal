import Darwin
import XCTest
@preconcurrency import SwiftTerm
@testable import Pane

final class TerminalInteractionControllerTests: XCTestCase {
    @MainActor
    func testBasicCommandReturnsComposerOwnership() {
        let machine = readyMachine()
        XCTAssertTrue(machine.handle(.commandSubmitted))
        XCTAssertEqual(machine.state, .commandRunningLineInput)
        XCTAssertTrue(machine.handle(.commandCompleted))
        XCTAssertEqual(machine.state, .shellIdle)
        XCTAssertEqual(machine.state.focusTarget, .composer)
    }

    @MainActor
    func testDirectInputFinishingWhileTerminalMountedReturnsCorrectOwner() {
        let machine = readyMachine()
        machine.handle(.commandStarted)
        machine.handle(.directInputRequired)
        XCTAssertEqual(machine.state.focusTarget, .authoritativeTerminal)
        machine.handle(.commandCompleted)
        XCTAssertEqual(machine.state, .shellIdle)
        XCTAssertEqual(machine.state.focusTarget, .composer)
    }

    @MainActor
    func testAlternateScreenBlockToTerminalSwitchDoesNotLoseInput() {
        let machine = readyMachine()
        machine.handle(.commandStarted)
        machine.handle(.directInputRequired)
        machine.handle(.alternateScreenEntered)
        XCTAssertEqual(machine.state, .alternateScreen)
        XCTAssertEqual(machine.state.focusTarget, .authoritativeTerminal)
        machine.handle(.alternateScreenExited)
        XCTAssertEqual(machine.state, .commandRunningDirect)
        machine.handle(.commandCompleted)
        XCTAssertEqual(machine.state.focusTarget, .composer)
    }

    @MainActor
    func testManualFullTerminalIsStickyAcrossCommands() {
        let machine = readyMachine()
        machine.handle(.userOpenedFullTerminal)
        machine.handle(.commandStarted)
        machine.handle(.commandCompleted)
        XCTAssertEqual(machine.state, .fullTerminal)
        machine.handle(.userReturnedToBlocks)
        XCTAssertEqual(machine.state, .shellIdle)
    }

    @MainActor
    func testReturningFromFullTerminalRestoresActiveDirectInteraction() {
        let machine = readyMachine()
        machine.handle(.commandStarted)
        machine.handle(.directInputRequired)
        machine.handle(.userOpenedFullTerminal)
        XCTAssertEqual(machine.state, .fullTerminal)

        machine.handle(.userReturnedToBlocks)
        XCTAssertEqual(machine.state, .commandRunningDirect)
        XCTAssertEqual(machine.state.focusTarget, .authoritativeTerminal)
    }

    @MainActor
    func testManualFullTerminalRemainsStickyAcrossAlternateScreenCompletion() {
        let machine = readyMachine()
        machine.handle(.userOpenedFullTerminal)
        machine.handle(.commandStarted)
        machine.handle(.alternateScreenEntered)
        XCTAssertEqual(machine.state, .alternateScreen)

        machine.handle(.commandCompleted)
        XCTAssertEqual(machine.state, .fullTerminal)
        machine.handle(.userReturnedToBlocks)
        XCTAssertEqual(machine.state, .shellIdle)
    }

    @MainActor
    func testLifecycleStatesRejectPresentationAndCommandEvents() {
        let machine = readyMachine()
        machine.handle(.restartRequested)

        XCTAssertFalse(machine.handle(.userOpenedFullTerminal))
        XCTAssertFalse(machine.handle(.commandStarted))
        XCTAssertEqual(machine.state, .restarting)

        machine.handle(.restartCompleted)
        machine.handle(.shellExited)
        XCTAssertFalse(machine.handle(.userOpenedFullTerminal))
        XCTAssertFalse(machine.handle(.commandStarted))
        XCTAssertEqual(machine.state, .stopped)
    }

    @MainActor
    func testSecurePromptHasNoComposerOwner() {
        let machine = readyMachine()
        machine.handle(.commandStarted)
        machine.handle(.secureInputRequired)
        XCTAssertEqual(machine.state, .commandRunningSecure)
        XCTAssertFalse(machine.state.composerEnabled)
        XCTAssertEqual(machine.state.inputRequirement, .secure)
        machine.handle(.secureInputEnded)
        machine.handle(.commandCompleted)
        XCTAssertEqual(machine.state, .shellIdle)
    }

    @MainActor
    func testProjectedPresentationAndInputComeFromInteractionController() {
        let machine = readyMachine()
        XCTAssertEqual(machine.presentationMode, .blocks)
        XCTAssertEqual(machine.effectiveInputRequirement, .shellIdle)
        XCTAssertTrue(machine.composerEnabled)
        XCTAssertFalse(machine.showsAuthoritativeTerminal)

        XCTAssertTrue(machine.handle(.userOpenedFullTerminal))
        XCTAssertEqual(machine.presentationMode, .terminal)
        XCTAssertEqual(machine.effectiveInputRequirement, .direct)
        XCTAssertFalse(machine.composerEnabled)
        XCTAssertTrue(machine.showsAuthoritativeTerminal)

        XCTAssertTrue(machine.handle(.secureInputRequired))
        XCTAssertEqual(machine.state, .fullTerminal)
        XCTAssertEqual(machine.effectiveInputRequirement, .secure)
        XCTAssertTrue(machine.handle(.secureInputEnded))
        XCTAssertEqual(machine.effectiveInputRequirement, .direct)

        XCTAssertTrue(machine.handle(.userReturnedToBlocks))
        XCTAssertEqual(machine.presentationMode, .blocks)
        XCTAssertEqual(machine.effectiveInputRequirement, .shellIdle)
        XCTAssertTrue(machine.composerEnabled)
    }

    @MainActor
    func testAlternateScreenAtIdleTemporarilyOwnsInput() {
        let machine = readyMachine()
        XCTAssertTrue(machine.handle(.alternateScreenEntered))
        XCTAssertEqual(machine.state, .alternateScreen)
        XCTAssertEqual(machine.effectiveInputRequirement, .direct)
        XCTAssertEqual(machine.state.focusTarget, .authoritativeTerminal)

        XCTAssertTrue(machine.handle(.alternateScreenExited))
        XCTAssertEqual(machine.state, .shellIdle)
        XCTAssertEqual(machine.effectiveInputRequirement, .shellIdle)
        XCTAssertEqual(machine.state.focusTarget, .composer)
    }

    @MainActor
    func testRestartDuringDirectInputDoesNotLeaveDeadFirstResponder() {
        let machine = readyMachine()
        machine.handle(.commandStarted)
        machine.handle(.directInputRequired)
        machine.handle(.restartRequested)
        XCTAssertEqual(machine.state, .restarting)
        XCTAssertEqual(machine.state.focusTarget, .none)
        machine.handle(.restartCompleted)
        XCTAssertEqual(machine.state.focusTarget, .composer)
    }

    @MainActor
    func testShellExitAndShutdownRemoveInputOwnership() {
        let exited = readyMachine()
        exited.handle(.commandStarted)
        exited.handle(.shellExited)
        XCTAssertEqual(exited.state, .stopped)
        XCTAssertFalse(exited.state.terminalAcceptsInput)

        let closing = readyMachine()
        closing.handle(.commandStarted)
        closing.handle(.applicationClosing)
        XCTAssertEqual(closing.state, .shuttingDown)
        XCTAssertEqual(closing.state.focusTarget, .none)
    }

    @MainActor
    func testUpdateNSViewCannotStealNewerFocusRequest() {
        let focus = FocusCoordinator()
        focus.request(.authoritativeTerminal)
        let staleGeneration = focus.generation
        focus.request(.composer)
        XCTAssertFalse(focus.isCurrent(.authoritativeTerminal, generation: staleGeneration))
        XCTAssertTrue(focus.isCurrent(.composer, generation: focus.generation))
    }

    @MainActor
    func testRepeatedFocusRequestInvalidatesOlderAsyncWork() {
        let focus = FocusCoordinator()
        focus.request(.authoritativeTerminal)
        let staleGeneration = focus.generation
        focus.request(.authoritativeTerminal)

        XCTAssertFalse(focus.isCurrent(.authoritativeTerminal, generation: staleGeneration))
        XCTAssertTrue(focus.isCurrent(.authoritativeTerminal, generation: focus.generation))
    }

    @MainActor
    func testDeterministicRandomizedTransitionsPreserveInvariants() {
        var random = LCRandom(seed: 82_481)
        let events: [TerminalInteractionEvent] = [
            .shellReady, .commandStarted, .directInputRequired, .secureInputRequired,
            .secureInputEnded, .alternateScreenEntered, .alternateScreenExited,
            .userOpenedFullTerminal, .userReturnedToBlocks, .commandCompleted,
            .commandInterrupted, .restartRequested, .restartCompleted, .shellExited
        ]

        for _ in 0..<25 {
            let machine = TerminalInteractionController()
            for _ in 0..<1_000 {
                _ = machine.handle(events[Int(random.next() % UInt64(events.count))])
                machine.assertInvariants()
                XCTAssertFalse(machine.state.focusTarget == .composer && machine.state.terminalAcceptsInput)
            }
        }
    }

    @MainActor
    private func readyMachine() -> TerminalInteractionController {
        let machine = TerminalInteractionController()
        XCTAssertTrue(machine.handle(.shellReady))
        return machine
    }
}

final class PTYGenerationGateTests: XCTestCase {
    func testStaleGenerationBytesAreRejectedAndTerminationIsExactlyOnce() {
        var gate = PTYGenerationGate()
        let generationA = gate.beginReplacement()
        XCTAssertTrue(gate.acceptsOutput(from: generationA))
        XCTAssertTrue(gate.acceptTermination(from: generationA))
        XCTAssertFalse(gate.acceptTermination(from: generationA))

        let generationB = gate.beginReplacement()
        XCTAssertFalse(gate.acceptsOutput(from: generationA))
        XCTAssertTrue(gate.acceptsOutput(from: generationB))
        XCTAssertFalse(gate.acceptTermination(from: generationA))
        XCTAssertTrue(gate.acceptTermination(from: generationB))
    }
}

final class PTYControllerTests: XCTestCase {
    @MainActor
    func testOneHundredProcessGenerationsReturnToBaseline() {
        var starts = 0
        var terminations = 0
        let controller = PTYController(
            terminationDelay: .nanoseconds(0),
            processFactory: { _ in
                FakePTYProcessDriver { event in
                    if event == "start" { starts += 1 }
                    if event == "terminate" { terminations += 1 }
                }
            }
        )
        let configuration = ShellConfiguration(
            executable: "/bin/zsh",
            arguments: ["-f"],
            environment: [],
            workingDirectory: "/tmp"
        )

        for _ in 0..<100 {
            XCTAssertTrue(controller.start(
                configuration: configuration,
                workingDirectory: "/tmp"
            ).isRunning)
            controller.terminate()
            XCTAssertFalse(controller.isRunning)
#if DEBUG
            XCTAssertFalse(controller.debugHasProcessReference)
#endif
        }

        XCTAssertEqual(starts, 100)
        XCTAssertEqual(terminations, 100)
    }

    @MainActor
    func testStartWriteResizeAndTerminateAreOwnedByController() {
        var drivers: [FakePTYProcessDriver] = []
        var delegates: [LocalProcessDelegate] = []
        var resizeRequests: [winsize] = []
        var lifecycle: [String] = []
        let controller = PTYController(
            terminationDelay: .nanoseconds(0),
            processFactory: { delegate in
                let driver = FakePTYProcessDriver(
                    lifecycle: { lifecycle.append($0) }
                )
                delegates.append(delegate)
                drivers.append(driver)
                return driver
            },
            resizeHandler: { _, size in resizeRequests.append(size) }
        )
        let configuration = ShellConfiguration(
            executable: "/bin/zsh",
            arguments: ["-f"],
            environment: [],
            workingDirectory: "/tmp"
        )

        let first = controller.start(
            configuration: configuration,
            workingDirectory: "/tmp"
        )
        XCTAssertEqual(first.generation, 1)
        XCTAssertTrue(first.isRunning)
        XCTAssertEqual(lifecycle, ["start"])
        XCTAssertTrue(controller.write([0x61, 0x62]))
        XCTAssertEqual(drivers[0].sentBytes, [[0x61, 0x62]])

        let unchanged = controller.windowSize
        XCTAssertFalse(controller.resize(to: unchanged))
        XCTAssertTrue(controller.resize(to: winsize(
            ws_row: 40,
            ws_col: 120,
            ws_xpixel: 1_200,
            ws_ypixel: 800
        )))
        XCTAssertEqual(resizeRequests.count, 1)
        XCTAssertEqual(resizeRequests[0].ws_col, 120)

        let second = controller.start(
            configuration: configuration,
            workingDirectory: "/tmp"
        )
        XCTAssertEqual(second.generation, 2)
        XCTAssertEqual(lifecycle, ["start", "terminate", "start"])
        XCTAssertFalse(drivers[0].running)
        XCTAssertTrue(drivers[1].running)
        XCTAssertEqual(delegates.count, 2)
    }

    @MainActor
    func testStaleCallbacksAndDuplicateTerminationNeverReachConsumer() {
        var drivers: [FakePTYProcessDriver] = []
        var delegates: [LocalProcessDelegate] = []
        let controller = PTYController(
            terminationDelay: .nanoseconds(0),
            processFactory: { delegate in
                let driver = FakePTYProcessDriver()
                delegates.append(delegate)
                drivers.append(driver)
                return driver
            }
        )
        var events: [PTYController.Event] = []
        controller.onEvent = { events.append($0) }
        let configuration = ShellConfiguration(
            executable: "/bin/zsh",
            arguments: [],
            environment: [],
            workingDirectory: "/tmp"
        )

        _ = controller.start(configuration: configuration, workingDirectory: "/tmp")
        delegates[0].dataReceived(slice: [0x41][...])
        _ = controller.start(configuration: configuration, workingDirectory: "/tmp")
        delegates[0].dataReceived(slice: [0x42][...])
        delegates[1].dataReceived(slice: [0x43][...])

        let source = LocalProcess(delegate: delegates[1], dispatchQueue: .main)
        delegates[1].processTerminated(source, exitCode: 0)
        delegates[1].processTerminated(source, exitCode: 0)

        XCTAssertEqual(events, [
            .received(Data([0x41])),
            .received(Data([0x43])),
            .terminated(waitStatus: 0)
        ])
        XCTAssertFalse(controller.isRunning)
        XCTAssertFalse(controller.write([0x44]))
        XCTAssertEqual(drivers.count, 2)
    }
}

@MainActor
private final class FakePTYProcessDriver: PTYProcessDriving {
    private(set) var running = false
    let childFileDescriptor: Int32 = 42
    let shellProcessID: pid_t = 0
    private(set) var sentBytes: [[UInt8]] = []

    private let lifecycle: (String) -> Void

    init(lifecycle: @escaping (String) -> Void = { _ in }) {
        self.lifecycle = lifecycle
    }

    func start(configuration: ShellConfiguration, workingDirectory: String) {
        lifecycle("start")
        running = true
    }

    func send(_ data: ArraySlice<UInt8>) {
        sentBytes.append(Array(data))
    }

    func terminate() {
        lifecycle("terminate")
        running = false
    }
}

private struct LCRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}
