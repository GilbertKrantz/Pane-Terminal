import Foundation

struct CompletionCandidate: Identifiable, Sendable {
    enum Source: Sendable { case zsh, history, executable, fileSystem, builtIn, localModel }
    let id: String
    let displayText: String
    let replacementText: String
    let source: Source
    let detail: String?
    let isDirectory: Bool
    var score: Double?
}

protocol CompletionRanking: Sendable {
    func rank(candidates: [CompletionCandidate], context: LocalAutocompleteContext) async -> [CompletionCandidate]
}

struct DeterministicCompletionRanker: CompletionRanking {
    func rank(candidates: [CompletionCandidate], context: LocalAutocompleteContext) async -> [CompletionCandidate] {
        candidates.enumerated().map { offset, candidate in
            var result = candidate
            result.score = Double(candidates.count - offset)
            return result
        }.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
    }
}
