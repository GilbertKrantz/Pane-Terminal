import Foundation
import XCTest
@testable import Pane

extension CommandAutocompleteTests {
    func testCompletionServicePublishesLocalThenMergesValidZsh() async throws {
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
        XCTAssertEqual(received.last?.first?.replacementText, "git-from-zsh")
        XCTAssertTrue(received.last?.contains { $0.replacementText == "git status" } == true)
    }

    func testCompletionServicePreservesWholeDraftEditForPartialHistoryPrefix() async throws {
        let directory = try makeTemporaryDirectory()
        let draft = "cd D"
        let context = LocalAutocompleteContext(
            draft: draft,
            cursorUTF16Offset: (draft as NSString).length,
            history: ["cd Documents/Work/Repo-gitlab/airflow-dags"],
            currentDirectory: directory,
            executableSearchPath: "",
            shellGeneration: 1
        )
        let service = CompletionService()
        let updates = await service.suggestions(for: context) {
            ZshCompletionProtocol.Response(
                requestID: "range-check",
                status: .ok,
                candidates: []
            )
        }

        var finalSuggestions: [CommandAutocompleteSuggestion] = []
        for await update in updates {
            finalSuggestions = update
        }
        let suggestion = try XCTUnwrap(finalSuggestions.first {
            CommandAutocomplete().accept($0, in: draft).draft
                == "cd Documents/Work/Repo-gitlab/airflow-dags"
        }, "Published replacements: \(finalSuggestions.map(\.replacementText))")

        XCTAssertEqual(suggestion.id,
                       "typedCompletion|false|cd Documents/Work/Repo-gitlab/airflow-dags")
        XCTAssertEqual(
            CommandAutocomplete().accept(suggestion, in: draft).draft,
            "cd Documents/Work/Repo-gitlab/airflow-dags"
        )
    }

    func testCompletionServiceTreatsValidEmptyZshAsAnEmptyContribution() async throws {
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
        XCTAssertTrue(final.contains { $0.replacementText == "git status" })
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

    func testSlowProviderTimesOutWithoutBlockingUsefulResults() async throws {
        let service = CompletionService()
        let request = makeCompletionRequest(generation: 1)
        let local = FakeCompletionProvider(
            identifier: .local,
            delay: .zero,
            values: [
                CompletionCandidate(
                    displayText: "git status",
                    replacementText: "git status",
                    source: .history,
                    kind: .fullCommand
                )
            ]
        )
        let slowZsh = FakeCompletionProvider(
            identifier: .zsh,
            delay: .milliseconds(100),
            values: []
        )

        let stream = await service.responses(
            for: request,
            providers: [local, slowZsh],
            budgets: [.zsh: .milliseconds(5)]
        )
        var responses: [CompletionResponse] = []
        for await response in stream { responses.append(response) }

        XCTAssertTrue(responses.contains {
            $0.candidates.contains { $0.candidate.replacementText == "git status" }
        })
        XCTAssertTrue(responses.last?.diagnostics.contains {
            $0.provider == .zsh && $0.timedOut
        } == true)
    }

    func testStagedProvidersNeverPublishDuplicateRowsAndKeepStableIdentity() async throws {
        let service = CompletionService()
        let request = makeCompletionRequest(
            generation: 1,
            draft: "git st",
            tokenRange: NSRange(location: 4, length: 2)
        )
        var historyEvidence = CompletionEvidence()
        historyEvidence.projectFrequency = 4
        var zshEvidence = CompletionEvidence()
        zshEvidence.acceptanceCount = 3
        let stream = await service.responses(
            for: request,
            providers: [
                FakeCompletionProvider(
                    identifier: .history,
                    delay: .zero,
                    values: [
                        CompletionCandidate(
                            displayText: "git status",
                            replacementText: "git status",
                            replacementRange: NSRange(location: 0, length: 6),
                            source: .history,
                            kind: .fullCommand,
                            evidence: historyEvidence
                        )
                    ]
                ),
                FakeCompletionProvider(
                    identifier: .zsh,
                    delay: .milliseconds(20),
                    values: [
                        CompletionCandidate(
                            displayText: "status",
                            replacementText: "status",
                            replacementRange: NSRange(location: 4, length: 2),
                            source: .zsh,
                            kind: .argument,
                            evidence: zshEvidence
                        )
                    ]
                )
            ]
        )

        var responses: [CompletionResponse] = []
        for await response in stream { responses.append(response) }

        XCTAssertGreaterThanOrEqual(responses.count, 2)
        for response in responses {
            XCTAssertEqual(Set(response.candidates.map(\.id)).count, response.candidates.count)
            XCTAssertEqual(response.candidates.count, 1)
            XCTAssertEqual(response.candidates[0].id, "typedCompletion|false|git status")
        }
        let final = try XCTUnwrap(responses.last?.candidates.first?.candidate)
        XCTAssertEqual(final.source, .zsh)
        XCTAssertEqual(final.supportingSources, [.zsh, .history])
        XCTAssertEqual(final.evidence.projectFrequency, 4)
        XCTAssertEqual(final.evidence.acceptanceCount, 3)
        XCTAssertEqual(final.feedbackIdentityAliases, [
            "argument|false|status",
            "fullCommand|false|git status"
        ])
    }

    func testLateProviderResponseCannotOverwriteNewRequest() async throws {
        let service = CompletionService()
        let first = await service.responses(
            for: makeCompletionRequest(generation: 1),
            providers: [
                FakeCompletionProvider(
                    identifier: .zsh,
                    delay: .milliseconds(80),
                    values: [
                        CompletionCandidate(
                            displayText: "stale",
                            replacementText: "stale",
                            source: .zsh
                        )
                    ]
                )
            ]
        )
        let firstCollector = Task {
            var values: [CompletionResponse] = []
            for await value in first { values.append(value) }
            return values
        }
        try await Task.sleep(for: .milliseconds(5))
        let second = await service.responses(
            for: makeCompletionRequest(generation: 2),
            providers: [
                FakeCompletionProvider(
                    identifier: .local,
                    delay: .zero,
                    values: [
                        CompletionCandidate(
                            displayText: "current",
                            replacementText: "current",
                            source: .history,
                            kind: .fullCommand
                        )
                    ]
                )
            ]
        )
        var current: [CompletionResponse] = []
        for await value in second { current.append(value) }
        let stale = await firstCollector.value

        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(current.last?.candidates.first?.candidate.replacementText, "current")
    }

}
