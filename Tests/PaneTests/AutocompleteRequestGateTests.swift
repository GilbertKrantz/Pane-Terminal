import XCTest
@testable import Pane

@MainActor
final class AutocompleteRequestGateTests: XCTestCase {
    private let sessionID = UUID()
    private let tabID = UUID()

    func testOlderGenerationCannotPublishOverNewerInput() throws {
        var gate = AutocompleteRequestGate()
        let old = try XCTUnwrap(gate.begin(input: "g", sessionID: sessionID, tabID: tabID))
        let current = try XCTUnwrap(gate.begin(input: "git", sessionID: sessionID, tabID: tabID))

        XCTAssertFalse(gate.permits(old, currentInput: "git", sessionID: sessionID, tabID: tabID))
        XCTAssertTrue(gate.permits(current, currentInput: "git", sessionID: sessionID, tabID: tabID))
    }

    func testClearInvalidatesRequestAndStartsNoEmptyRequest() throws {
        var gate = AutocompleteRequestGate()
        let request = try XCTUnwrap(gate.begin(input: "git", sessionID: sessionID, tabID: tabID))

        XCTAssertNil(gate.begin(input: " \n", sessionID: sessionID, tabID: tabID))
        XCTAssertFalse(gate.permits(request, currentInput: "", sessionID: sessionID, tabID: tabID))
        XCTAssertNil(gate.context)
    }

    func testSubmissionInvalidationRejectsPendingResult() throws {
        var gate = AutocompleteRequestGate()
        let request = try XCTUnwrap(gate.begin(input: "ls", sessionID: sessionID, tabID: tabID))

        gate.invalidate()

        XCTAssertFalse(gate.permits(request, currentInput: "ls", sessionID: sessionID, tabID: tabID))
    }

    func testRequestIsScopedToSessionAndTab() throws {
        var gate = AutocompleteRequestGate()
        let request = try XCTUnwrap(gate.begin(input: "git", sessionID: sessionID, tabID: tabID))

        XCTAssertFalse(gate.permits(request, currentInput: "git", sessionID: UUID(), tabID: tabID))
        XCTAssertFalse(gate.permits(request, currentInput: "git", sessionID: sessionID, tabID: UUID()))
    }

    func testQueryValidationIsTrimmedButCaseSensitive() throws {
        var gate = AutocompleteRequestGate()
        let request = try XCTUnwrap(gate.begin(input: "  Git ", sessionID: sessionID, tabID: tabID))

        XCTAssertTrue(gate.permits(request, currentInput: "Git", sessionID: sessionID, tabID: tabID))
        XCTAssertFalse(gate.permits(request, currentInput: "git", sessionID: sessionID, tabID: tabID))
    }
}
