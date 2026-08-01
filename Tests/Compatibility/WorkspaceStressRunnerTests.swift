import Foundation
import XCTest
@testable import Pane

@MainActor
final class WorkspaceStressRunnerTests: XCTestCase {
    func testFakePTYBaselineExercisesExactP2ContractWithoutCrossover()
        async throws {
        let result = try await WorkspaceStressRunner(
            configuration: .baseline,
            backend: .fake
        ).run()

        XCTAssertEqual(result.initialTabCount, 12)
        XCTAssertEqual(result.commandsPerTab, 20)
        XCTAssertEqual(result.commandCount, 12 * 20)
        XCTAssertEqual(result.switchCount, 500)
        XCTAssertEqual(result.backgroundProducerCount, 6)
        XCTAssertEqual(result.alternateScreenCount, 3)
        XCTAssertEqual(result.closedTabIDs.count, 6)
        XCTAssertEqual(result.replacementTabIDs.count, 6)
        XCTAssertEqual(result.survivingTabIDs.count, 12)
        XCTAssertEqual(result.finalMarkerOwners.count, 12)
        XCTAssertTrue(result.outputIsolationViolations.isEmpty)
        XCTAssertTrue(result.inputIsolationViolations.isEmpty)
        XCTAssertTrue(result.focusIsolationViolations.isEmpty)
        XCTAssertTrue(result.resizeIsolationViolations.isEmpty)
        XCTAssertTrue(result.secureStateIsolationViolations.isEmpty)
        XCTAssertEqual(result.terminalIdentityChangeCount, 0)
        XCTAssertEqual(result.ptyGenerationChangeCount, 0)
        XCTAssertTrue(result.closingTabIDsAfterCleanup.isEmpty)
        XCTAssertFalse(
            result.pendingFocusTabIDAfterCleanup.map(
                result.closedTabIDs.contains
            ) ?? false
        )
        XCTAssertTrue(result.closeCleanupConverged)
        XCTAssertLessThan(result.maximumCloseDuration, 2)
    }

    func testRealPTYBaselineWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment[
            "PANE_RUN_REAL_STRESS"
        ] == "1" else {
            throw XCTSkip(
                "Enable the opt-in isolated-zsh baseline with PANE_RUN_REAL_STRESS=1"
            )
        }

        let result = try await WorkspaceStressRunner(
            configuration: .baseline,
            backend: .realPTY
        ).run()

        XCTAssertEqual(result.initialTabCount, 12)
        XCTAssertEqual(result.commandCount, 240)
        XCTAssertEqual(result.switchCount, 500)
        XCTAssertEqual(result.closedTabIDs.count, 6)
        XCTAssertEqual(result.replacementTabIDs.count, 6)
        XCTAssertEqual(result.finalMarkerOwners.count, 12)
        XCTAssertTrue(result.outputIsolationViolations.isEmpty)
        XCTAssertTrue(result.inputIsolationViolations.isEmpty)
        XCTAssertTrue(result.focusIsolationViolations.isEmpty)
        XCTAssertTrue(result.resizeIsolationViolations.isEmpty)
        XCTAssertTrue(result.secureStateIsolationViolations.isEmpty)
        XCTAssertEqual(result.terminalIdentityChangeCount, 0)
        XCTAssertEqual(result.ptyGenerationChangeCount, 0)
        XCTAssertTrue(result.closingTabIDsAfterCleanup.isEmpty)
        XCTAssertTrue(result.closeCleanupConverged)
    }
}
