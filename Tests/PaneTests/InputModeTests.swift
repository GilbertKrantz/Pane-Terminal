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
    func testModeSwitcherPresentationRestoresSliderGeometry() {
        XCTAssertEqual(ModeSwitcherPresentation.segmentWidth, 76)
        XCTAssertEqual(ModeSwitcherPresentation.segmentHeight, 26)
        XCTAssertEqual(ModeSwitcherPresentation.trackInset, 3)
        XCTAssertEqual(
            (ModeSwitcherPresentation.segmentWidth * 2)
                + (ModeSwitcherPresentation.trackInset * 2),
            158
        )
    }

    func testModeSwitcherPresentationRespectsReducedMotion() {
        XCTAssertTrue(
            ModeSwitcherPresentation.shouldAnimateSelection(reduceMotion: false)
        )
        XCTAssertFalse(
            ModeSwitcherPresentation.shouldAnimateSelection(reduceMotion: true)
        )
    }

    func testModeSwitcherPresentationExposesSelectionToAccessibility() {
        XCTAssertEqual(
            ModeSwitcherPresentation.accessibilityValue(
                for: .blocks,
                selection: .blocks
            ),
            "Selected"
        )
        XCTAssertEqual(
            ModeSwitcherPresentation.accessibilityValue(
                for: .terminal,
                selection: .blocks
            ),
            "Not selected"
        )
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
            isRawInput: false,
            echoEnabled: false
        )

        XCTAssertFalse(snapshot.echoEnabled)
        XCTAssertTrue(snapshot.requiresSecureInputFromTermios)
        XCTAssertNil(snapshot.terminalModeAttribution)
    }

    func testRawInteractiveInputIsNotMistakenForSecureInput() {
        let snapshot = ForegroundProcessSnapshot(
            processGroupID: 42,
            shellProcessGroupID: 7,
            processName: "python3",
            isRawInput: true,
            echoEnabled: false
        )

        XCTAssertFalse(snapshot.requiresSecureInputFromTermios)
        XCTAssertEqual(
            snapshot.terminalModeAttribution,
            .rawTermios("python3")
        )
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
