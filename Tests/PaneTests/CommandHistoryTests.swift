import XCTest
@testable import Pane

final class CommandHistoryTests: XCTestCase {
    func testContinuationCanReplaceMostRecentEntry() {
        var history = CommandHistory()
        history.append("if true; then")

        history.replaceMostRecent(with: "if true; then\necho yes\nfi")

        XCTAssertEqual(history.commands, ["if true; then\necho yes\nfi"])
    }

    func testNavigatesBackwardAndForwardAndRestoresDraft() {
        var history = CommandHistory()
        history.append("pwd")
        history.append("git status")

        XCTAssertEqual(history.previous(currentDraft: "unfinished"), "git status")
        XCTAssertEqual(history.previous(currentDraft: "git status"), "pwd")
        XCTAssertEqual(history.next(currentDraft: "pwd"), "git status")
        XCTAssertEqual(history.next(currentDraft: "git status"), "unfinished")
    }

    func testConsecutiveDuplicateIsStoredOnce() {
        var history = CommandHistory()
        history.append("ls")
        history.append("ls")

        XCTAssertEqual(history.count, 1)
    }

    func testEmptyCommandIsNotStored() {
        var history = CommandHistory()
        history.append("")

        XCTAssertEqual(history.count, 0)
    }

    func testHistoryRetainsOnlyNewestConfiguredEntries() {
        var history = CommandHistory(limit: 3)
        for index in 0..<5 {
            history.append("echo \(index)")
        }

        XCTAssertEqual(history.commands, ["echo 2", "echo 3", "echo 4"])
        XCTAssertEqual(history.previous(currentDraft: ""), "echo 4")
        XCTAssertEqual(history.previous(currentDraft: ""), "echo 3")
        XCTAssertEqual(history.previous(currentDraft: ""), "echo 2")
    }
}
