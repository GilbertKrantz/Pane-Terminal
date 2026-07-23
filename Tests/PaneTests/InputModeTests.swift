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

    func testKnownInteractiveFallbackRecognizesNormalBufferAgentTUIs() {
        for processName in ["codex", "claude", "opencode", "node"] {
            XCTAssertTrue(
                ForegroundProcessSnapshot.isKnownInteractiveProgram(named: processName),
                "Expected \(processName) to request direct input"
            )
        }
        XCTAssertFalse(ForegroundProcessSnapshot.isKnownInteractiveProgram(named: "brew"))
        XCTAssertFalse(ForegroundProcessSnapshot.isKnownInteractiveProgram(named: "tail"))
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

    func testTerminalInputRequirementModelsBlockFirstStates() {
        XCTAssertEqual(TerminalInputRequirement.shellIdle, .shellIdle)
        XCTAssertNotEqual(TerminalInputRequirement.lineOriented, .direct)
        XCTAssertNotEqual(TerminalInputRequirement.secure, .direct)
    }


    func testTerminalPresentationIsIndependentFromInputRequirement() {
        XCTAssertNotEqual(ActiveTerminalPresentation.authoritativeInBlock, .expanded)
        XCTAssertNotEqual(ActiveTerminalPresentation.hidden, .liveMirror)
        XCTAssertNotEqual(ActiveTerminalPresentation.fullTerminal, .authoritativeInBlock)
    }

    func testSecureInputAttributionIsExplicit() {
        XCTAssertEqual(
            InputModeAttribution.secureInput.explanation,
            "secure input is active"
        )
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
