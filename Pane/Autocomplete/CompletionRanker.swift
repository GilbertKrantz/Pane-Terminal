import Foundation

enum CompletionSource: String, Codable, Sendable, CaseIterable {
    case zsh, history, builtIn, executable, fileSystem
    case projectScript, projectCommand, transition
}

enum CompletionKind: String, Codable, Sendable {
    case command, argument, path, option, script, fullCommand, nextCommand
}

struct CompletionEvidence: Sendable, Equatable {
    var exactPrefixMatch = false
    var prefixMatchLength = 0
    var sessionFrequency = 0
    var projectFrequency = 0
    var globalFrequency = 0
    var sessionRecency: TimeInterval?
    var projectRecency: TimeInterval?
    var globalRecency: TimeInterval?
    var transitionFrequency = 0
    var previousCommandMatch = false
    var projectMatch = false
    var workingDirectoryMatch = false
    var executableAvailable = false
    var historicalSuccessRate: Double?
    var acceptanceCount = 0
    var dismissalCount = 0
}

struct CompletionCandidate: Identifiable, Sendable {
    let id: String
    let displayText: String
    let replacementText: String
    let replacementRange: NSRange?
    let source: CompletionSource
    var supportingSources: Set<CompletionSource>
    var feedbackIdentityAliases: Set<String>
    let kind: CompletionKind
    let detail: String?
    let isDirectory: Bool
    var evidence: CompletionEvidence

    init(
        id: String? = nil,
        displayText: String,
        replacementText: String,
        replacementRange: NSRange? = nil,
        source: CompletionSource,
        kind: CompletionKind = .command,
        detail: String? = nil,
        isDirectory: Bool = false,
        evidence: CompletionEvidence = CompletionEvidence(),
        supportingSources: Set<CompletionSource>? = nil,
        feedbackIdentityAliases: Set<String>? = nil
    ) {
        let normalizedIDText = replacementText.replacingOccurrences(
            of: #"\s+$"#,
            with: "",
            options: .regularExpression
        )
        let rangeIdentity = replacementRange.map {
            "\($0.location):\($0.length)"
        } ?? "default"
        self.id = id
            ?? "\(kind.rawValue):\(isDirectory):\(rangeIdentity):\(normalizedIDText)"
        self.displayText = displayText
        self.replacementText = replacementText
        self.replacementRange = replacementRange
        self.source = source
        self.supportingSources = supportingSources ?? [source]
        self.feedbackIdentityAliases = feedbackIdentityAliases ?? [
            "\(kind.rawValue)|\(isDirectory)|\(normalizedIDText)"
        ]
        self.kind = kind
        self.detail = detail
        self.isDirectory = isDirectory
        self.evidence = evidence
    }
}

enum CompletionResultCategory: String, Hashable, Sendable {
    case typedCompletion
    case nextCommand
}

/// Provider-independent identity for the text that accepting a completion puts
/// in the composer.  `resultingText` deliberately remains shell-sensitive.
struct CompletionResultIdentity: Hashable, Sendable {
    let resultingText: String
    let category: CompletionResultCategory
    let isDirectory: Bool

    var stableID: String { "\(category.rawValue)|\(isDirectory)|\(resultingText)" }
}

struct ResolvedCompletionCandidate: Sendable {
    let candidate: CompletionCandidate
    let result: CompletionResultIdentity
}

enum CompletionCandidateResolver {
    static func resolve(
        _ candidate: CompletionCandidate,
        request: CompletionRequest
    ) -> ResolvedCompletionCandidate? {
        guard let result = candidate.resultIdentity(for: request) else { return nil }
        return ResolvedCompletionCandidate(candidate: candidate, result: result)
    }
}

extension CompletionCandidate {
    func resultIdentity(for request: CompletionRequest) -> CompletionResultIdentity? {
        guard let result = resultingText(for: request) else { return nil }
        return CompletionResultIdentity(
            resultingText: Self.canonicalResult(result),
            category: kind == .nextCommand ? .nextCommand : .typedCompletion,
            isDirectory: isDirectory
        )
    }

    func resultingText(for request: CompletionRequest) -> String? {
        let range: NSRange
        if let replacementRange {
            range = replacementRange
        } else {
            switch kind {
            case .fullCommand, .nextCommand, .script:
                range = NSRange(location: 0, length: (request.draft as NSString).length)
            case .command, .argument, .path, .option:
                range = request.tokenContext.replacementRange
            }
        }
        return replacingUTF16Range(in: request.draft, range: range, with: replacementText)
    }

    private static func canonicalResult(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
    }
}

/// Converts an NSRange without interpreting UTF-16 offsets as Characters and
/// rejects boundaries which split a surrogate pair.
func replacingUTF16Range(in text: String, range: NSRange, with replacement: String) -> String? {
    let utf16 = text.utf16
    guard range.location != NSNotFound,
          range.location >= 0, range.length >= 0,
          range.location <= utf16.count,
          range.length <= utf16.count - range.location else { return nil }
    let utf16Start = utf16.index(utf16.startIndex, offsetBy: range.location)
    let utf16End = utf16.index(utf16Start, offsetBy: range.length)
    guard let start = String.Index(utf16Start, within: text),
          let end = String.Index(utf16End, within: text) else { return nil }
    return text.replacingCharacters(in: start..<end, with: replacement)
}

enum CompletionRankReason: String, Sendable {
    case source, exactPrefix, prefix, project, directory, transition, recency
    case frequency, success, accepted, dismissed
}

struct RankedCompletion: Identifiable, Sendable {
    let candidate: CompletionCandidate
    let score: Double
    let rankReasons: [CompletionRankReason]
    var id: String { candidate.id }
}

struct CompletionRankingWeights: Sendable {
    var zshBase = 60.0
    var projectScriptBase = 55.0
    var projectCommandBase = 50.0
    var transitionBase = 45.0
    var historyBase = 40.0
    var builtInBase = 25.0
    var executableBase = 20.0
    var fileSystemBase = 15.0
    var exactPrefix = 50.0
    var sameProject = 35.0
    var sameDirectory = 25.0
    var previousTransition = 30.0
    var maximumRecencyBoost = 30.0
    var maximumFrequencyBoost = 25.0
    var maximumAcceptanceBoost = 24.0
    var maximumDismissalPenalty = 20.0
    var maximumSuccessBoost = 15.0

    static let `default` = CompletionRankingWeights()
}

/// Pure, deterministic ranking. Counts use logarithmic saturation so old habits
/// remain useful without permanently crowding out newer commands.
struct CompletionRanker: Sendable {
    let weights: CompletionRankingWeights
    init(weights: CompletionRankingWeights = .default) { self.weights = weights }

    func rank(_ input: [CompletionCandidate], request: CompletionRequest,
              maximumResults: Int = .max) -> [RankedCompletion] {
        deduplicate(input, request: request).map(score).sorted(by: precedes)
            .prefix(max(0, maximumResults)).map { $0 }
    }

    func rankCanonical(
        _ candidates: [CompletionCandidate],
        maximumResults: Int = .max
    ) -> [RankedCompletion] {
        candidates.map(score).sorted(by: precedes)
            .prefix(max(0, maximumResults)).map { $0 }
    }

    func deduplicate(_ candidates: [CompletionCandidate], request: CompletionRequest) -> [CompletionCandidate] {
        deduplicate(candidates.compactMap {
            CompletionCandidateResolver.resolve($0, request: request)
        }).map(\.candidate)
    }

    func deduplicate(
        _ candidates: [ResolvedCompletionCandidate]
    ) -> [ResolvedCompletionCandidate] {
        var order: [CompletionResultIdentity] = []
        var values: [CompletionResultIdentity: CompletionCandidate] = [:]
        for resolved in candidates {
            let candidate = resolved.candidate
            let identity = resolved.result
            guard let existing = values[identity] else {
                order.append(identity)
                values[identity] = withStableID(candidate, identity: identity)
                continue
            }
            values[identity] = merge(existing, candidate, identity: identity)
        }
        return order.compactMap { identity in
            values[identity].map { ResolvedCompletionCandidate(candidate: $0, result: identity) }
        }
    }

    private func merge(_ existing: CompletionCandidate, _ candidate: CompletionCandidate,
                       identity: CompletionResultIdentity) -> CompletionCandidate {
        let primary = stronger(candidate, than: existing) ? candidate : existing
        let operation = saferOperation(candidate, than: existing) ? candidate : existing
        var sources = existing.supportingSources
        sources.formUnion(candidate.supportingSources)
        sources.insert(existing.source); sources.insert(candidate.source)
        let details = [existing, candidate]
        let detail = details.first { $0.source == .zsh && !($0.detail ?? "").isEmpty }?.detail
            ?? details.first { $0.source == .projectScript && !($0.detail ?? "").isEmpty }?.detail
            ?? primary.detail ?? details.first { !($0.detail ?? "").isEmpty }?.detail
        return CompletionCandidate(
            id: identity.stableID,
            displayText: primary.displayText,
            replacementText: operation.replacementText,
            replacementRange: operation.replacementRange,
            source: primary.source,
            kind: primary.kind,
            detail: detail,
            isDirectory: primary.isDirectory,
            evidence: merge(existing.evidence, candidate.evidence),
            supportingSources: sources,
            feedbackIdentityAliases: existing.feedbackIdentityAliases
                .union(candidate.feedbackIdentityAliases)
        )
    }

    private func withStableID(_ candidate: CompletionCandidate,
                              identity: CompletionResultIdentity) -> CompletionCandidate {
        CompletionCandidate(id: identity.stableID, displayText: candidate.displayText,
            replacementText: candidate.replacementText, replacementRange: candidate.replacementRange,
            source: candidate.source, kind: candidate.kind, detail: candidate.detail,
            isDirectory: candidate.isDirectory, evidence: candidate.evidence,
            supportingSources: candidate.supportingSources,
            feedbackIdentityAliases: candidate.feedbackIdentityAliases)
    }

    private func stronger(_ lhs: CompletionCandidate, than rhs: CompletionCandidate) -> Bool {
        if sourceBase(lhs.source) != sourceBase(rhs.source) {
            return sourceBase(lhs.source) > sourceBase(rhs.source)
        }
        if (lhs.replacementRange != nil) != (rhs.replacementRange != nil) {
            return lhs.replacementRange != nil
        }
        return !(lhs.detail ?? "").isEmpty && (rhs.detail ?? "").isEmpty
    }

    private func saferOperation(_ lhs: CompletionCandidate, than rhs: CompletionCandidate) -> Bool {
        let lhsExplicit = lhs.replacementRange != nil
        let rhsExplicit = rhs.replacementRange != nil
        if lhsExplicit != rhsExplicit { return lhsExplicit }
        if lhs.source == .zsh && rhs.source != .zsh { return true }
        if rhs.source == .zsh && lhs.source != .zsh { return false }
        let lhsLength = lhs.replacementRange?.length ?? Int.max
        let rhsLength = rhs.replacementRange?.length ?? Int.max
        if lhsLength != rhsLength {
            // Whole-command candidates intentionally replace the complete
            // draft. Preserve that semantic operation when canonical
            // deduplication merges it with a token-sized edit that happens to
            // produce the same resulting composer text.
            switch lhs.kind {
            case .fullCommand, .nextCommand, .script:
                return lhsLength > rhsLength
            case .command, .argument, .path, .option:
                return lhsLength < rhsLength
            }
        }
        return stronger(lhs, than: rhs)
    }

    private func merge(_ a: CompletionEvidence, _ b: CompletionEvidence) -> CompletionEvidence {
        var value = a
        value.exactPrefixMatch = a.exactPrefixMatch || b.exactPrefixMatch
        value.prefixMatchLength = max(a.prefixMatchLength, b.prefixMatchLength)
        value.sessionFrequency = max(a.sessionFrequency, b.sessionFrequency)
        value.projectFrequency = max(a.projectFrequency, b.projectFrequency)
        value.globalFrequency = max(a.globalFrequency, b.globalFrequency)
        value.sessionRecency = minimum(a.sessionRecency, b.sessionRecency)
        value.projectRecency = minimum(a.projectRecency, b.projectRecency)
        value.globalRecency = minimum(a.globalRecency, b.globalRecency)
        value.transitionFrequency = max(a.transitionFrequency, b.transitionFrequency)
        value.previousCommandMatch = a.previousCommandMatch || b.previousCommandMatch
        value.projectMatch = a.projectMatch || b.projectMatch
        value.workingDirectoryMatch = a.workingDirectoryMatch || b.workingDirectoryMatch
        value.executableAvailable = a.executableAvailable || b.executableAvailable
        switch (a.historicalSuccessRate, b.historicalSuccessRate) {
        case let (lhs?, rhs?):
            value.historicalSuccessRate = max(lhs, rhs)
        case let (lhs?, nil):
            value.historicalSuccessRate = lhs
        case let (nil, rhs?):
            value.historicalSuccessRate = rhs
        case (nil, nil):
            value.historicalSuccessRate = nil
        }
        value.acceptanceCount = max(a.acceptanceCount, b.acceptanceCount)
        value.dismissalCount = max(a.dismissalCount, b.dismissalCount)
        return value
    }

    private func minimum(_ a: TimeInterval?, _ b: TimeInterval?) -> TimeInterval? {
        switch (a, b) { case let (x?, y?): return min(x, y); case let (x?, nil): return x; case let (nil, y?): return y; default: return nil }
    }

    private func score(_ candidate: CompletionCandidate) -> RankedCompletion {
        let e = candidate.evidence
        var score = sourceBase(candidate.source)
        var reasons: [CompletionRankReason] = [.source]
        if e.exactPrefixMatch { score += weights.exactPrefix; reasons.append(.exactPrefix) }
        else if e.prefixMatchLength > 0 { score += min(30, Double(e.prefixMatchLength) * 3); reasons.append(.prefix) }
        if e.projectMatch { score += weights.sameProject; reasons.append(.project) }
        if e.workingDirectoryMatch { score += weights.sameDirectory; reasons.append(.directory) }
        if e.previousCommandMatch { score += weights.previousTransition; reasons.append(.transition) }
        if e.transitionFrequency > 0 { score += bounded(e.transitionFrequency, maximum: 15); reasons.append(.transition) }
        let recency = [e.sessionRecency, e.projectRecency, e.globalRecency].compactMap { $0 }.min()
        if let recency { score += recencyBoost(age: recency); reasons.append(.recency) }
        let frequency = e.sessionFrequency * 3 + e.projectFrequency * 2 + e.globalFrequency
        if frequency > 0 { score += bounded(frequency, maximum: weights.maximumFrequencyBoost); reasons.append(.frequency) }
        if let success = e.historicalSuccessRate { score += min(1, max(0, success)) * weights.maximumSuccessBoost; reasons.append(.success) }
        if e.acceptanceCount > 0 { score += bounded(e.acceptanceCount, maximum: weights.maximumAcceptanceBoost); reasons.append(.accepted) }
        if e.dismissalCount > 0 { score -= bounded(e.dismissalCount, maximum: weights.maximumDismissalPenalty); reasons.append(.dismissed) }
        return RankedCompletion(candidate: candidate, score: score, rankReasons: reasons)
    }

    private func bounded(_ count: Int, maximum: Double) -> Double { min(maximum, log1p(Double(max(0, count))) * 5) }
    private func recencyBoost(age: TimeInterval) -> Double {
        let boost: Double
        switch max(0, age) { case ..<300: boost = 30; case ..<3600: boost = 24; case ..<86_400: boost = 18; case ..<604_800: boost = 10; case ..<2_592_000: boost = 4; default: boost = 0 }
        return min(weights.maximumRecencyBoost, boost)
    }
    private func sourceBase(_ source: CompletionSource) -> Double {
        switch source { case .zsh: return weights.zshBase; case .projectScript: return weights.projectScriptBase; case .projectCommand: return weights.projectCommandBase; case .transition: return weights.transitionBase; case .history: return weights.historyBase; case .builtIn: return weights.builtInBase; case .executable: return weights.executableBase; case .fileSystem: return weights.fileSystemBase }
    }
    private func precedes(_ lhs: RankedCompletion, _ rhs: RankedCompletion) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.candidate.evidence.exactPrefixMatch != rhs.candidate.evidence.exactPrefixMatch { return lhs.candidate.evidence.exactPrefixMatch }
        let lb = sourceBase(lhs.candidate.source), rb = sourceBase(rhs.candidate.source)
        if lb != rb { return lb > rb }
        if lhs.candidate.evidence.projectMatch != rhs.candidate.evidence.projectMatch { return lhs.candidate.evidence.projectMatch }
        return lhs.candidate.replacementText.localizedStandardCompare(rhs.candidate.replacementText) == .orderedAscending
    }
}

protocol CompletionRanking: Sendable {
    func rank(candidates: [CompletionCandidate], request: CompletionRequest) async -> [CompletionCandidate]
}

struct DeterministicCompletionRanker: CompletionRanking {
    let ranker = CompletionRanker()
    func rank(candidates: [CompletionCandidate], request: CompletionRequest) async -> [CompletionCandidate] {
        ranker.rank(candidates, request: request).map(\.candidate)
    }
}
