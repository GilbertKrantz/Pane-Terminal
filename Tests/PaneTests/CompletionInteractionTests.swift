import Foundation
import XCTest
@testable import Pane

extension CommandAutocompleteTests {
    func testHistorySuggestionsUseCurrentSessionRecencyAndCommandContext() throws {
        let currentDirectory = try makeTemporaryDirectory()
        let autocomplete = CommandAutocomplete(
            maximumSuggestions: 10,
            builtInCommands: []
        )

        let suggestions = autocomplete.suggestions(
            for: "git st",
            history: [
                "git stash",
                "git status --short",
                "git store"
            ],
            currentDirectory: currentDirectory,
            executableSearchPath: ""
        )

        XCTAssertEqual(suggestions.map(\.text), ["store", "status", "stash"])
        XCTAssertEqual(suggestions.map(\.source), [.history, .history, .history])
    }

    func testAcceptingFullCommandHistoryReplacesDraftInsteadOfDuplicatingPrefix() {
        let autocomplete = CommandAutocomplete()
        let suggestion = CommandAutocompleteSuggestion(
            text: "cd Documents/Work/repo-github/",
            replacementText: "cd Documents/Work/repo-github/",
            replacementRange: NSRange(location: 0, length: 4),
            source: .history,
            detail: "Command history"
        )

        let edit = autocomplete.accept(
            suggestion,
            in: "cd D",
            cursorUTF16Offset: 4
        )

        XCTAssertEqual(edit.draft, "cd Documents/Work/repo-github/")
        XCTAssertEqual(
            edit.cursorUTF16Offset,
            ("cd Documents/Work/repo-github/" as NSString).length
        )
    }

    func testFullCommandHistoryCarriesWholeDraftReplacementRange() async throws {
        let directory = try makeTemporaryDirectory()
        let provider = LocalAutocompleteProvider(maximumSuggestions: 12)
        let draft = "cd D"
        let suggestions = await provider.suggestions(
            for: LocalAutocompleteContext(
                draft: draft,
                cursorUTF16Offset: (draft as NSString).length,
                history: ["cd Documents/Work/repo-github/"],
                currentDirectory: directory,
                executableSearchPath: "",
                shellGeneration: 1
            )
        )
        let suggestion = try XCTUnwrap(suggestions.first {
            $0.replacementText == "cd Documents/Work/repo-github/"
        })

        XCTAssertEqual(
            suggestion.replacementRange,
            NSRange(location: 0, length: (draft as NSString).length)
        )
        XCTAssertEqual(
            CommandAutocomplete().accept(suggestion, in: draft).draft,
            "cd Documents/Work/repo-github/"
        )
    }

    func testAcceptingTokenHistoryStillReplacesOnlyCurrentToken() {
        let autocomplete = CommandAutocomplete()
        let suggestion = CommandAutocompleteSuggestion(
            text: "status",
            replacementText: "status",
            source: .history
        )

        let edit = autocomplete.accept(
            suggestion,
            in: "git st --short",
            cursorUTF16Offset: 6
        )

        XCTAssertEqual(edit.draft, "git status --short")
        XCTAssertEqual(edit.cursorUTF16Offset, 10)
    }

    func testHistorySuggestionsSupportMultilineDrafts() throws {
        let currentDirectory = try makeTemporaryDirectory()
        let autocomplete = CommandAutocomplete(builtInCommands: [])

        let suggestions = autocomplete.suggestions(
            for: "echo first\ncat ph",
            history: ["echo first\ncat photo.png"],
            currentDirectory: currentDirectory,
            executableSearchPath: ""
        )

        XCTAssertEqual(suggestions.map(\.text), ["photo.png"])
        let edit = autocomplete.accept(suggestions[0], in: "echo first\ncat ph")
        XCTAssertEqual(edit.draft, "echo first\ncat photo.png")
    }

    func testBuiltInsAreDeterministicAndResultCountIsCapped() throws {
        let currentDirectory = try makeTemporaryDirectory()
        let autocomplete = CommandAutocomplete(
            maximumSuggestions: 2,
            builtInCommands: ["garden", "gamut", "gamma", "gamma"]
        )

        let suggestions = autocomplete.suggestions(
            for: "ga",
            history: [],
            currentDirectory: currentDirectory,
            executableSearchPath: ""
        )

        XCTAssertEqual(suggestions.map(\.text), ["gamma", "gamut"])
        XCTAssertEqual(suggestions.map(\.source), [.builtIn, .builtIn])
    }

    func testPATHSuggestionsIncludeOnlyExecutableFilesAndDeduplicateNames() throws {
        let currentDirectory = try makeTemporaryDirectory()
        let firstBin = currentDirectory.appendingPathComponent("first-bin", isDirectory: true)
        let secondBin = currentDirectory.appendingPathComponent("second-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: firstBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondBin, withIntermediateDirectories: true)

        try makeExecutable(named: "pane", in: firstBin)
        try makeExecutable(named: "pane-tool", in: firstBin)
        try makeExecutable(named: "pane", in: secondBin)
        _ = FileManager.default.createFile(
            atPath: secondBin.appendingPathComponent("panec").path,
            contents: Data()
        )
        try FileManager.default.createDirectory(
            at: secondBin.appendingPathComponent("pane-directory"),
            withIntermediateDirectories: false
        )

        let autocomplete = CommandAutocomplete(builtInCommands: [])
        let suggestions = autocomplete.suggestions(
            for: "pan",
            history: [],
            currentDirectory: currentDirectory,
            executableSearchPath: "second-bin:first-bin"
        )

        XCTAssertEqual(suggestions.map(\.text), ["pane", "pane-tool"])
        XCTAssertEqual(suggestions.map(\.source), [.executable, .executable])
    }

    func testExecutablesAreOnlySuggestedAtACommandPosition() throws {
        let currentDirectory = try makeTemporaryDirectory()
        let bin = currentDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try makeExecutable(named: "git", in: bin)

        let suggestions = CommandAutocomplete(builtInCommands: []).suggestions(
            for: "echo gi",
            history: [],
            currentDirectory: currentDirectory,
            executableSearchPath: "bin"
        )

        XCTAssertFalse(suggestions.contains { $0.source == .executable })
    }

    func testFileSystemSuggestionsResolveAgainstProvidedCurrentDirectory() throws {
        let currentDirectory = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: currentDirectory.appendingPathComponent("Documents"),
            withIntermediateDirectories: false
        )
        _ = FileManager.default.createFile(
            atPath: currentDirectory.appendingPathComponent("Dockerfile").path,
            contents: Data()
        )
        _ = FileManager.default.createFile(
            atPath: currentDirectory.appendingPathComponent(".dotfile").path,
            contents: Data()
        )

        let suggestions = CommandAutocomplete(builtInCommands: []).suggestions(
            for: "cat Do",
            history: [],
            currentDirectory: currentDirectory,
            executableSearchPath: ""
        )

        XCTAssertEqual(suggestions.map(\.text), ["Dockerfile", "Documents/"])
        XCTAssertEqual(suggestions.map(\.source), [.fileSystem, .fileSystem])
        XCTAssertFalse(suggestions[0].isDirectory)
        XCTAssertTrue(suggestions[1].isDirectory)
    }

    func testAcceptEscapesPathSpaces() throws {
        let currentDirectory = try makeTemporaryDirectory()
        _ = FileManager.default.createFile(
            atPath: currentDirectory.appendingPathComponent("My File.txt").path,
            contents: Data()
        )
        let autocomplete = CommandAutocomplete(builtInCommands: [])
        let suggestions = autocomplete.suggestions(
            for: "cat My",
            history: [],
            currentDirectory: currentDirectory,
            executableSearchPath: ""
        )

        XCTAssertEqual(suggestions.map(\.text), ["My File.txt"])
        XCTAssertEqual(suggestions[0].replacementText, "My\\ File.txt")
        XCTAssertEqual(
            autocomplete.accept(suggestions[0], in: "cat My").draft,
            "cat My\\ File.txt"
        )
    }

    func testAcceptReplacesOnlyCurrentTokenAndPreservesMultilineDraft() {
        let autocomplete = CommandAutocomplete()
        let draft = "echo first\ncat old.txt --flag"
        let tokenRange = (draft as NSString).range(of: "old.txt")
        let cursor = tokenRange.location + 3
        let suggestion = CommandAutocompleteSuggestion(
            text: "new.txt",
            source: .fileSystem
        )

        let edit = autocomplete.accept(
            suggestion,
            in: draft,
            cursorUTF16Offset: cursor
        )

        XCTAssertEqual(edit.draft, "echo first\ncat new.txt --flag")
        XCTAssertEqual(
            edit.cursorUTF16Offset,
            tokenRange.location + ("new.txt" as NSString).length
        )
    }

    func testCapturedSuggestionsPreserveCompsysContext() {
        let candidates = [
            ZshCompletionCandidate(
                replacementText: "--verbose",
                detail: "Print additional progress",
                isDirectory: false
            ),
            ZshCompletionCandidate(
                replacementText: "checkout",
                detail: "Switch branches or restore working tree files",
                isDirectory: false
            ),
            ZshCompletionCandidate(
                replacementText: "Sources/",
                detail: nil,
                isDirectory: true
            )
        ]

        let suggestions = CommandAutocomplete().capturedSuggestions(candidates)

        XCTAssertEqual(suggestions.map(\.source), [.zsh, .zsh, .zsh])
        XCTAssertEqual(suggestions.map(\.replacementText), ["--verbose", "checkout", "Sources/"])
        XCTAssertEqual(
            suggestions.map(\.detail),
            [
                "Print additional progress",
                "Switch branches or restore working tree files",
                nil
            ]
        )
        XCTAssertFalse(suggestions[0].isDirectory)
        XCTAssertTrue(suggestions[2].isDirectory)
    }

    func testKeyboardSelectionCyclesWithoutChangingSuggestionOrder() {
        let suggestions = [
            CommandAutocompleteSuggestion(text: "checkout", source: .zsh),
            CommandAutocompleteSuggestion(text: "cherry-pick", source: .zsh),
            CommandAutocompleteSuggestion(text: "clean", source: .zsh)
        ]
        var selection = CommandAutocompleteSelection()

        XCTAssertTrue(selection.move(by: 1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "checkout")
        XCTAssertTrue(selection.move(by: 1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "cherry-pick")
        XCTAssertTrue(selection.move(by: 1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "clean")
        XCTAssertTrue(selection.move(by: 1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "checkout")
    }

    func testSingleSuggestionRequiresTwoTabsBeforeAccepting() {
        let suggestion = CommandAutocompleteSuggestion(text: "status", source: .zsh)
        let suggestions = [suggestion]
        var selection = CommandAutocompleteSelection()

        XCTAssertNil(selection.selected(from: suggestions))
        XCTAssertEqual(selection.handleTab(by: 1, through: suggestions), .cycle)
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "status")
        XCTAssertEqual(
            selection.handleTab(by: 1, through: suggestions),
            .accept(suggestion)
        )
        XCTAssertNil(selection.selected(from: suggestions))
    }

    func testKeyboardSelectionMovesBackwardAndResetsForEmptyResults() {
        let suggestions = [
            CommandAutocompleteSuggestion(text: "main", source: .zsh),
            CommandAutocompleteSuggestion(text: "master", source: .zsh)
        ]
        var selection = CommandAutocompleteSelection()

        XCTAssertTrue(selection.move(by: -1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "master")
        XCTAssertTrue(selection.move(by: -1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "main")
        XCTAssertFalse(selection.move(by: 1, through: []))
        XCTAssertNil(selection.highlightedSuggestionID)
    }

    func testCapturedSuggestionsAreDeduplicatedAndCappedWithoutReordering() {
        let candidates = (0..<20).map { index in
            ZshCompletionCandidate(
                replacementText: index == 1 ? "match-0" : "match-\(index)",
                detail: "detail-\(index)",
                isDirectory: false
            )
        }

        let suggestions = CommandAutocomplete(maximumSuggestions: 3)
            .capturedSuggestions(candidates)

        XCTAssertEqual(suggestions.map(\.replacementText), ["match-0", "match-2", "match-3"])
        XCTAssertEqual(suggestions.map(\.detail), ["detail-0", "detail-2", "detail-3"])
    }

    func testExecutableIndexInvalidatesWhenPATHChanges() async throws {
        let root = try makeTemporaryDirectory()
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try makeExecutable(named: "pane-first", in: first)
        try makeExecutable(named: "pane-second", in: second)
        let index = ExecutableIndex(ttl: 120)

        let initial = await index.candidates(prefix: "pane-", path: first.path, currentDirectory: root, shellGeneration: 1)
        let changed = await index.candidates(prefix: "pane-", path: second.path, currentDirectory: root, shellGeneration: 1)

        XCTAssertEqual(initial, ["pane-first"])
        XCTAssertEqual(changed, ["pane-second"])
    }

    func testExecutableIndexDoesNotReuseRelativePATHAcrossDirectories() async throws {
        let firstCWD = try makeTemporaryDirectory()
        let secondCWD = try makeTemporaryDirectory()
        try makeExecutable(named: "cwd-first", in: firstCWD)
        try makeExecutable(named: "cwd-second", in: secondCWD)
        let index = ExecutableIndex(ttl: 120)

        let first = await index.candidates(prefix: "cwd-", path: "", currentDirectory: firstCWD, shellGeneration: 1)
        let second = await index.candidates(prefix: "cwd-", path: "", currentDirectory: secondCWD, shellGeneration: 1)

        XCTAssertEqual(first, ["cwd-first"])
        XCTAssertEqual(second, ["cwd-second"])
    }

}
