import Foundation
import XCTest
@testable import Pane

final class CommandAutocompleteTests: XCTestCase {
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

    func testCompletionServicePublishesLocalThenReplacesItWithValidZsh() async throws {
        let directory = try makeTemporaryDirectory()
        let context = LocalAutocompleteContext(
            draft: "gi",
            cursorUTF16Offset: 2,
            history: ["git status"],
            currentDirectory: directory,
            executableSearchPath: "",
            shellGeneration: 1
        )
        let service = CompletionService()
        let updates = await service.suggestions(for: context) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            return ZshCompletionProtocol.Response(
                requestID: "request-1",
                status: .ok,
                candidates: [
                    .init(
                        replacementText: "git-from-zsh",
                        detail: "zsh",
                        isDirectory: false
                    )
                ]
            )
        }

        var received: [[CommandAutocompleteSuggestion]] = []
        for await update in updates {
            received.append(update)
        }

        XCTAssertGreaterThanOrEqual(received.count, 2)
        XCTAssertFalse(received[0].isEmpty)
        XCTAssertEqual(received.last?.map(\.replacementText), ["git-from-zsh"])
        XCTAssertEqual(received.last?.first?.source, .zsh)
    }

    func testCompletionServiceTreatsValidEmptyZshAsAuthoritative() async throws {
        let directory = try makeTemporaryDirectory()
        let context = LocalAutocompleteContext(
            draft: "gi",
            cursorUTF16Offset: 2,
            history: ["git status"],
            currentDirectory: directory,
            executableSearchPath: "",
            shellGeneration: 1
        )
        let service = CompletionService()
        let updates = await service.suggestions(for: context) {
            ZshCompletionProtocol.Response(
                requestID: "request-2",
                status: .ok,
                candidates: []
            )
        }

        var final: [CommandAutocompleteSuggestion] = []
        for await update in updates {
            final = update
        }
        XCTAssertTrue(final.isEmpty)
    }

    func testCompletionServiceDoesNotPublishAfterContextBecomesInvalid() async throws {
        let directory = try makeTemporaryDirectory()
        let context = LocalAutocompleteContext(
            draft: "gi",
            cursorUTF16Offset: 2,
            history: ["git status"],
            currentDirectory: directory,
            executableSearchPath: "",
            shellGeneration: 1
        )
        let service = CompletionService()
        let updates = await service.suggestions(
            for: context,
            zsh: {
                ZshCompletionProtocol.Response(
                    requestID: "request-3",
                    status: .ok,
                    candidates: []
                )
            },
            isValid: { false }
        )

        var received: [[CommandAutocompleteSuggestion]] = []
        for await update in updates {
            received.append(update)
        }
        XCTAssertTrue(received.isEmpty)
    }

    func testValidEmptyCapturedResultDoesNotBecomeLocalHeuristicSuggestions() throws {
        let root = try makeTemporaryDirectory()
        _ = FileManager.default.createFile(
            atPath: root.appendingPathComponent("local-heuristic-match").path,
            contents: Data()
        )
        let autocomplete = CommandAutocomplete(builtInCommands: [])

        // A non-nil empty array is a successful zsh capture. The caller must
        // map it directly; only capture failure (`nil`) may use local fallback.
        let captured: [ZshCompletionCandidate] = []
        XCTAssertEqual(autocomplete.capturedSuggestions(captured), [])

        let fallback = autocomplete.suggestions(
            for: "pane-fixture local",
            history: [],
            currentDirectory: root,
            executableSearchPath: ""
        )
        XCTAssertEqual(fallback.map(\.replacementText), ["local-heuristic-match"])
    }

    func testWarmZshRequestFramePreservesBufferCursorAndDeadline() throws {
        let deadline = Date(timeIntervalSince1970: 1_750_000_000.125)
        let request = try XCTUnwrap(
            ZshCompletionProtocol.requestBytes(
                requestID: "g7-r42",
                buffer: "git checkout café",
                cursorCharacterOffset: 17,
                deadline: deadline
            )
        )
        let header = request.prefix(ZshCompletionProtocol.headerByteCount)
        let bodyLength = try XCTUnwrap(
            ZshCompletionProtocol.bodyLength(
                fromHeader: Data(header),
                maximum: ZshCompletionProtocol.maximumRequestBodyBytes
            )
        )
        let body = request.dropFirst(ZshCompletionProtocol.headerByteCount)
        XCTAssertEqual(bodyLength, body.count)

        let fields = body.split(
            separator: UInt8(ascii: ";"),
            maxSplits: 4,
            omittingEmptySubsequences: false
        )
        XCTAssertEqual(fields.count, 5)
        XCTAssertEqual(String(decoding: fields[0], as: UTF8.self), "1")
        XCTAssertEqual(String(decoding: fields[1], as: UTF8.self), "g7-r42")
        XCTAssertEqual(String(decoding: fields[2], as: UTF8.self), "1750000000125")
        XCTAssertEqual(String(decoding: fields[3], as: UTF8.self), "17")
        XCTAssertEqual(
            Data(base64Encoded: Data(fields[4])).map { String(decoding: $0, as: UTF8.self) },
            "git checkout café"
        )
    }

    func testWarmZshResponseFrameDecodesLengthPrefixedCandidate() throws {
        let candidateStream = Data("PZC11:9:--verbose9:Show more0".utf8)
        let body = Data(
            "1;g2-r3;ok;\(candidateStream.base64EncodedString())".utf8
        )
        let response = try XCTUnwrap(
            ZshCompletionProtocol.parseResponseBody(body)
        )

        XCTAssertEqual(response.requestID, "g2-r3")
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(
            response.candidates,
            [
                ZshCompletionProtocol.Candidate(
                    replacementText: "--verbose",
                    detail: "Show more",
                    isDirectory: false
                )
            ]
        )
        XCTAssertNil(
            ZshCompletionProtocol.bodyLength(
                fromHeader: Data("0000000G".utf8),
                maximum: ZshCompletionProtocol.maximumResponseBodyBytes
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PaneAutocompleteTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeExecutable(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
