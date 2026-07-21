import XCTest
@testable import Pane

final class InputModeTests: XCTestCase {
    func testToggleMovesBetweenBlocksAndTerminalModes() {
        var mode = InputMode.blocks

        mode.toggle()
        XCTAssertEqual(mode, .terminal)

        mode.toggle()
        XCTAssertEqual(mode, .blocks)
    }

    func testModeTitlesAreUserFacing() {
        XCTAssertEqual(InputMode.blocks.title, "Blocks Mode")
        XCTAssertEqual(InputMode.terminal.title, "Terminal Mode")
        XCTAssertEqual(InputMode.blocks.shortTitle, "Blocks")
        XCTAssertEqual(InputMode.terminal.shortTitle, "Terminal")
    }
}

extension InputModeTests {
    func testForegroundSnapshotRecognizesInteractivePrograms() {
        let snapshot = ForegroundProcessSnapshot(
            processGroupID: 42,
            shellProcessGroupID: 7,
            processName: "ssh",
            isRawInput: false,
            echoEnabled: true
        )

        XCTAssertTrue(snapshot.isKnownInteractiveProgram)
        XCTAssertEqual(snapshot.terminalModeAttribution, .foregroundProcess("ssh"))
    }

    func testForegroundSnapshotUsesRawTermiosAsTerminalSignal() {
        let snapshot = ForegroundProcessSnapshot(
            processGroupID: 42,
            shellProcessGroupID: 7,
            processName: "remote-app",
            isRawInput: true,
            echoEnabled: false
        )

        XCTAssertEqual(snapshot.terminalModeAttribution, .rawTermios("remote-app"))
    }

    func testForegroundSnapshotRecognizesShellForeground() {
        let snapshot = ForegroundProcessSnapshot(
            processGroupID: 42,
            shellProcessGroupID: 42,
            processName: "zsh",
            isRawInput: true,
            echoEnabled: false
        )

        XCTAssertTrue(snapshot.isShellForeground)
        XCTAssertTrue(snapshot.isRawInput)
        XCTAssertNil(snapshot.terminalModeAttribution)
    }


    func testTerminalSecurityStateReflectsDisabledEcho() {
        let state = TerminalSecurityState(
            inputMode: .secure,
            echoEnabled: false,
            detectedAt: Date(),
            source: .terminalEchoState
        )

        XCTAssertEqual(state.inputMode, .secure)
        XCTAssertFalse(state.echoEnabled)
        XCTAssertEqual(state.source, .terminalEchoState)
    }

    func testForegroundSnapshotCarriesEchoStateForSecureInputDetection() {
        let snapshot = ForegroundProcessSnapshot(
            processGroupID: 42,
            shellProcessGroupID: 7,
            processName: "sudo",
            isRawInput: true,
            echoEnabled: false
        )

        XCTAssertFalse(snapshot.echoEnabled)
        XCTAssertEqual(snapshot.terminalModeAttribution, .rawTermios("sudo"))
    }

    func testModeAttributionExplanationsAreUserFacing() {
        XCTAssertEqual(
            InputModeAttribution.foregroundProcess("ssh").explanation,
            "ssh is running"
        )
        XCTAssertEqual(
            InputModeAttribution.rawTermios("python").explanation,
            "python requested raw input"
        )
    }
}
