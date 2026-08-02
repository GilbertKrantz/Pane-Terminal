import Foundation

struct CompletionPipelineResult: Sendable {
    let ranked: [RankedCompletion]
    let rawCount: Int
    let canonicalCount: Int
    let duplicateCount: Int
    let invalidCount: Int
}

/// Pure completion processing. Request and provider lifetimes remain owned by
/// `CompletionService`; this value only transforms one accumulated snapshot.
struct CompletionPipeline: Sendable {
    private let ranker: CompletionRanker

    init(ranker: CompletionRanker = CompletionRanker()) {
        self.ranker = ranker
    }

    func process(
        candidates: [CompletionCandidate],
        request: CompletionRequest,
        store: (any BehavioralCompletionStore)? = nil,
        maximumResults: Int? = nil
    ) async -> CompletionPipelineResult {
        let resolved = candidates.compactMap {
            CompletionCandidateResolver.resolve($0, request: request)
        }
        let canonical = ranker.deduplicate(resolved)
        let enriched = await enrich(canonical.map(\.candidate), using: store, request: request)
        let ranked = ranker.rankCanonical(
            enriched,
            maximumResults: max(0, maximumResults ?? request.maximumResults)
        )
        return CompletionPipelineResult(
            ranked: ranked,
            rawCount: candidates.count,
            canonicalCount: canonical.count,
            duplicateCount: max(0, resolved.count - canonical.count),
            invalidCount: candidates.count - resolved.count
        )
    }

    private func enrich(
        _ candidates: [CompletionCandidate],
        using store: (any BehavioralCompletionStore)?,
        request: CompletionRequest
    ) async -> [CompletionCandidate] {
        guard let store, !candidates.isEmpty else { return candidates }
        // Read canonical feedback and bounded legacy representations during
        // migration; new pipeline candidates always carry a canonical ID.
        let identities = Array(Set(candidates.flatMap { [$0.id] + $0.feedbackIdentityAliases }))
        guard let aggregates = try? await store.feedbackAggregates(
            candidateIdentities: identities,
            projectID: request.projectContext?.identity,
            directoryIdentity: request.currentDirectory.standardizedFileURL.path,
            limit: min(500, identities.count * 3)
        ) else { return candidates }
        let grouped = Dictionary(grouping: aggregates, by: \.candidateIdentity)
        return candidates.map { candidate in
            var candidate = candidate
            let values = (grouped[candidate.id] ?? [])
                + candidate.feedbackIdentityAliases.flatMap { grouped[$0] ?? [] }
            for feedback in values {
                candidate.evidence.acceptanceCount = max(
                    candidate.evidence.acceptanceCount,
                    feedback.acceptanceCount
                )
                candidate.evidence.dismissalCount = max(
                    candidate.evidence.dismissalCount,
                    feedback.dismissalCount + feedback.replacementCount / 2
                )
            }
            return candidate
        }
    }
}
