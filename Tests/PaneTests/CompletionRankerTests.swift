import Foundation
import XCTest
@testable import Pane

extension CommandAutocompleteTests {
    func testCompletionRankerMergesEvidenceAndPrefersProjectProvider() {
        var historyEvidence = CompletionEvidence()
        historyEvidence.sessionFrequency = 4
        var projectEvidence = CompletionEvidence()
        projectEvidence.projectMatch = true
        projectEvidence.workingDirectoryMatch = true

        let request = makeCompletionRequest(
            generation: 1,
            draft: "npm run te",
            tokenRange: NSRange(location: 0, length: 10)
        )
        let ranked = CompletionRanker().rank([
            CompletionCandidate(
                displayText: "npm run test",
                replacementText: "npm run test",
                source: .history,
                kind: .fullCommand,
                evidence: historyEvidence
            ),
            CompletionCandidate(
                displayText: "npm run test",
                replacementText: "npm run test",
                source: .projectScript,
                kind: .fullCommand,
                detail: "package.json",
                evidence: projectEvidence
            )
        ], request: request)

        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked[0].candidate.source, .projectScript)
        XCTAssertEqual(ranked[0].candidate.detail, "package.json")
        XCTAssertEqual(ranked[0].candidate.evidence.sessionFrequency, 4)
        XCTAssertTrue(ranked[0].candidate.evidence.projectMatch)
    }

    func testRecentCommandOutranksOlderCommandUsingTimestamps() {
        let now = Date()
        var recentEvidence = CompletionEvidence()
        recentEvidence.globalRecency = now.timeIntervalSince(now.addingTimeInterval(-60))
        var oldEvidence = CompletionEvidence()
        oldEvidence.globalRecency = now.timeIntervalSince(now.addingTimeInterval(-40 * 24 * 60 * 60))
        let request = makeCompletionRequest(
            generation: 1,
            draft: "",
            tokenRange: NSRange(location: 0, length: 0)
        )
        let ranked = CompletionRanker().rank([
            CompletionCandidate(
                displayText: "old",
                replacementText: "old",
                source: .history,
                kind: .fullCommand,
                evidence: oldEvidence
            ),
            CompletionCandidate(
                displayText: "recent",
                replacementText: "recent",
                source: .history,
                kind: .fullCommand,
                evidence: recentEvidence
            )
        ], request: request)
        XCTAssertEqual(ranked.first?.candidate.replacementText, "recent")
    }

    func testNormalizedCommandFrequencyDoesNotUseSubstringMatching() async throws {
        let directory = try makeTemporaryDirectory()
        let provider = LocalAutocompleteProvider()
        let suggestions = await provider.suggestions(for: LocalAutocompleteContext(
            draft: "te",
            cursorUTF16Offset: 2,
            history: ["pytest", "npm run test", "test"],
            currentDirectory: directory,
            executableSearchPath: "",
            shellGeneration: 1
        ))
        XCTAssertEqual(
            suggestions.first { $0.replacementText == "test" }?.text,
            "test"
        )
        XCTAssertFalse(suggestions.contains {
            $0.replacementText == "pytest" || $0.replacementText == "npm run test"
        })
    }

    func testSecureEligibilityRejectsProviderWork() {
        XCTAssertEqual(
            CompletionEligibility.evaluate(
                interactionState: .commandRunningSecure,
                shellReady: true,
                secureInputActive: true,
                draft: "secret",
                cursorUTF16Offset: 6
            ),
            .secureInput
        )
    }

    func testDifferentReplacementRangesProducingSameResultMerge() {
        let request = makeCompletionRequest(generation: 1, draft: "git st",
            tokenRange: NSRange(location: 4, length: 2))
        let merged = CompletionRanker().deduplicate([
            CompletionCandidate(displayText: "status", replacementText: "status",
                replacementRange: NSRange(location: 4, length: 2), source: .zsh, kind: .argument),
            CompletionCandidate(displayText: "git status", replacementText: "git status",
                replacementRange: NSRange(location: 0, length: 6), source: .history, kind: .fullCommand)
        ], request: request)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .zsh)
        XCTAssertEqual(merged[0].replacementRange, NSRange(location: 4, length: 2))
        XCTAssertEqual(merged[0].supportingSources, [.zsh, .history])
        XCTAssertEqual(merged[0].id, "typedCompletion|false|git status")
    }

    func testCanonicalIdentityPreservesSemanticDifferences() {
        let request = makeCompletionRequest(generation: 1, draft: "git st",
            tokenRange: NSRange(location: 4, length: 2))
        let values = ["git status", "git Status", "git checkout -- foo", "git checkout foo",
                      "cd folder", "cd folder/", "echo 'foo bar'", "echo foo\\ bar"]
        let candidates = values.map {
            CompletionCandidate(displayText: $0, replacementText: $0,
                replacementRange: NSRange(location: 0, length: 6), source: .history,
                kind: .fullCommand)
        }
        XCTAssertEqual(CompletionRanker().deduplicate(candidates, request: request).count, values.count)
    }

    func testSameReplacementAtDifferentRangesDoesNotMergeWhenResultsDiffer() {
        let request = makeCompletionRequest(generation: 1, draft: "echo foo bar",
            tokenRange: NSRange(location: 9, length: 3))
        let candidates = [
            CompletionCandidate(displayText: "baz", replacementText: "baz",
                replacementRange: NSRange(location: 5, length: 3), source: .history, kind: .argument),
            CompletionCandidate(displayText: "baz", replacementText: "baz",
                replacementRange: NSRange(location: 9, length: 3), source: .zsh, kind: .argument)
        ]
        let merged = CompletionRanker().deduplicate(candidates, request: request)
        XCTAssertEqual(Set(merged.compactMap { $0.resultIdentity(for: request)?.resultingText }),
                       ["echo baz bar", "echo foo baz"])
    }

    func testProjectScriptAndHistoryProducingSameCommandMerge() {
        let request = makeCompletionRequest(generation: 1, draft: "npm r",
            tokenRange: NSRange(location: 4, length: 1))
        var projectEvidence = CompletionEvidence()
        projectEvidence.projectMatch = true
        var historyEvidence = CompletionEvidence()
        historyEvidence.projectFrequency = 6
        let merged = CompletionRanker().deduplicate([
            CompletionCandidate(displayText: "test", replacementText: "npm run test",
                replacementRange: NSRange(location: 0, length: 5), source: .projectScript,
                kind: .script, evidence: projectEvidence),
            CompletionCandidate(displayText: "npm run test", replacementText: "npm run test",
                replacementRange: NSRange(location: 0, length: 5), source: .history,
                kind: .fullCommand, evidence: historyEvidence)
        ], request: request)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .projectScript)
        XCTAssertEqual(merged[0].supportingSources, [.projectScript, .history])
        XCTAssertTrue(merged[0].evidence.projectMatch)
        XCTAssertEqual(merged[0].evidence.projectFrequency, 6)
    }

    func testCanonicalDeduplicationMeetsThousandCandidateLatencyTarget() {
        let request = makeCompletionRequest(generation: 1, draft: "git st",
            tokenRange: NSRange(location: 4, length: 2))
        let candidates = (0..<500).flatMap { index in
            let result = "git status-\(index)"
            return [
                CompletionCandidate(displayText: "status-\(index)", replacementText: "status-\(index)",
                    replacementRange: NSRange(location: 4, length: 2), source: .zsh, kind: .argument),
                CompletionCandidate(displayText: result, replacementText: result,
                    replacementRange: NSRange(location: 0, length: 6), source: .history, kind: .fullCommand)
            ]
        }
        let clock = ContinuousClock()
        let started = clock.now
        let merged = CompletionRanker().deduplicate(candidates, request: request)
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(merged.count, 500)
        XCTAssertLessThan(elapsed, .milliseconds(15))
    }

    func testNextCommandAndDirectoryRemainDistinct() {
        let request = makeCompletionRequest(generation: 1, draft: "",
            tokenRange: NSRange(location: 0, length: 0))
        let candidates = [
            CompletionCandidate(displayText: "Documents", replacementText: "Documents",
                source: .history, kind: .fullCommand),
            CompletionCandidate(displayText: "Documents", replacementText: "Documents",
                source: .transition, kind: .nextCommand),
            CompletionCandidate(displayText: "Documents", replacementText: "Documents",
                source: .fileSystem, kind: .path, isDirectory: true)
        ]
        XCTAssertEqual(CompletionRanker().deduplicate(candidates, request: request).count, 3)
    }

    func testCanonicalIdentityHandlesUnicodeAndRejectsSplitSurrogateRange() {
        let request = makeCompletionRequest(generation: 1, draft: "echo 😀x",
            tokenRange: NSRange(location: 5, length: 3))
        let valid = CompletionCandidate(displayText: "😀y", replacementText: "😀y",
            replacementRange: NSRange(location: 5, length: 3), source: .zsh, kind: .argument)
        let invalid = CompletionCandidate(displayText: "bad", replacementText: "bad",
            replacementRange: NSRange(location: 6, length: 1), source: .zsh, kind: .argument)
        XCTAssertEqual(valid.resultIdentity(for: request)?.resultingText, "echo 😀y")
        XCTAssertNil(invalid.resultIdentity(for: request))
        XCTAssertEqual(CompletionRanker().deduplicate([valid, invalid], request: request).count, 1)
    }

    func testTrailingWhitespaceDoesNotCreateDuplicate() {
        let request = makeCompletionRequest(generation: 1, draft: "git",
            tokenRange: NSRange(location: 0, length: 3))
        let candidates = ["git status", "git status   "].map {
            CompletionCandidate(displayText: $0, replacementText: $0,
                replacementRange: NSRange(location: 0, length: 3), source: .history,
                kind: .fullCommand)
        }
        XCTAssertEqual(CompletionRanker().deduplicate(candidates, request: request).count, 1)
    }

}
