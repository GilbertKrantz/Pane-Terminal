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
        supportingSources: Set<CompletionSource>? = nil
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
        self.kind = kind
        self.detail = detail
        self.isDirectory = isDirectory
        self.evidence = evidence
    }
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

    func rank(_ input: [CompletionCandidate], maximumResults: Int = .max) -> [RankedCompletion] {
        let merged = deduplicate(input)
        return merged.map(score).sorted(by: precedes).prefix(max(0, maximumResults)).map { $0 }
    }

    func deduplicate(_ candidates: [CompletionCandidate]) -> [CompletionCandidate] {
        var order: [String] = []
        var values: [String: CompletionCandidate] = [:]
        for candidate in candidates {
            let key = identity(for: candidate)
            guard let existing = values[key] else {
                order.append(key); values[key] = candidate; continue
            }
            let stronger = sourceBase(candidate.source) > sourceBase(existing.source) ? candidate : existing
            let evidence = merge(existing.evidence, candidate.evidence)
            var merged = stronger
            merged.evidence = evidence
            merged.supportingSources.formUnion(existing.supportingSources)
            merged.supportingSources.formUnion(candidate.supportingSources)
            // Prefer useful provider detail without changing executable text.
            if stronger.detail == nil, let detail = (stronger.id == existing.id ? candidate : existing).detail {
                merged = CompletionCandidate(id: stronger.id, displayText: stronger.displayText,
                    replacementText: stronger.replacementText,
                    replacementRange: stronger.replacementRange,
                    source: stronger.source, kind: stronger.kind,
                    detail: detail, isDirectory: stronger.isDirectory, evidence: evidence,
                    supportingSources: merged.supportingSources)
            }
            values[key] = merged
        }
        return order.compactMap { values[$0] }
    }

    private func identity(for candidate: CompletionCandidate) -> String {
        let trimmed = candidate.replacementText.replacingOccurrences(
            of: #"\s+$"#, with: "", options: .regularExpression)
        let range = candidate.replacementRange.map {
            "\($0.location):\($0.length)"
        } ?? "default"
        return "\(candidate.kind.rawValue)|\(candidate.isDirectory)|\(range)|\(trimmed)"
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
    func rank(candidates: [CompletionCandidate], context: LocalAutocompleteContext) async -> [CompletionCandidate]
}

struct DeterministicCompletionRanker: CompletionRanking {
    let ranker = CompletionRanker()
    func rank(candidates: [CompletionCandidate], context: LocalAutocompleteContext) async -> [CompletionCandidate] {
        ranker.rank(candidates).map(\.candidate)
    }
}
