import Foundation

struct CommandTokenContext: Sendable, Equatable {
    let replacementRange: NSRange
    let decodedPrefix: String
    let isCommandPosition: Bool
}

struct CompletedCommandSummary: Sendable, Equatable {
    let normalizedCommand: String
    let commandKey: String
    let exitCode: Int32?
    let projectID: String?
    let directoryIdentity: String?
    let completedAt: Date
}

struct CompletionRequest: Sendable {
    let id: UUID
    let generation: UInt64
    let draft: String
    let cursorUTF16Offset: Int
    let tokenContext: CommandTokenContext
    let currentDirectory: URL
    let projectContext: ProjectContext?
    let previousCommand: CompletedCommandSummary?
    let executableSearchPath: String
    let shellGeneration: UInt64
    let maximumResults: Int
    let createdAt: ContinuousClock.Instant
}

enum CompletionEligibilityResult: Equatable {
    case eligible, shellUnavailable, composerUnavailable, secureInput, restarting
    case shuttingDown, unsupportedCursorContext
}

struct CompletionEligibility {
    static func evaluate(interactionState: TerminalInteractionState, shellReady: Bool,
                         secureInputActive: Bool, draft: String,
                         cursorUTF16Offset: Int) -> CompletionEligibilityResult {
        if secureInputActive || interactionState == .commandRunningSecure { return .secureInput }
        if interactionState == .restarting { return .restarting }
        if interactionState == .shuttingDown { return .shuttingDown }
        guard shellReady else { return .shellUnavailable }
        guard interactionState.composerEnabled else { return .composerUnavailable }
        guard cursorUTF16Offset >= 0,
              cursorUTF16Offset <= (draft as NSString).length else {
            return .unsupportedCursorContext
        }
        return .eligible
    }
}

enum CompletionProviderID: String, Sendable, CaseIterable { case zsh, local, history, project, transition }
protocol CompletionProvider: Sendable {
    var identifier: CompletionProviderID { get }
    func candidates(for request: CompletionRequest) async throws -> [CompletionCandidate]
}
enum CompletionProviderError: Error { case timedOut, cancelled }

func withTimeout<T: Sendable>(_ duration: Duration,
                              operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            try Task.checkCancellation()
            throw CompletionProviderError.timedOut
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw CompletionProviderError.cancelled }
        return value
    }
}

struct CompletionProviderDiagnostic: Sendable {
    let provider: CompletionProviderID
    let elapsed: Duration
    let candidateCount: Int
    let cacheHit: Bool
    let timedOut: Bool
    let cancelled: Bool
    let errorCategory: String?
}

struct CompletionResponse: Sendable {
    let requestID: UUID
    let generation: UInt64
    let candidates: [RankedCompletion]
    let elapsed: Duration
    let diagnostics: [CompletionProviderDiagnostic]
    let isFinal: Bool
}

#if DEBUG
struct CompletionDebugSnapshot: Sendable {
    let requestID: UUID?
    let generation: UInt64
    let inFlightProviders: Set<CompletionProviderID>
    let lastDiagnostics: [CompletionProviderDiagnostic]
    let rawCandidateCount: Int
    let mergedCandidateCount: Int
    let publishedCandidateCount: Int
    let staleResponseCount: Int
    let timeoutCount: Int
    let rankingDuration: Duration?
    let projectID: String?
}
#endif

struct CompletionCandidateIdentity: Hashable, Sendable {
    let normalizedReplacement: String
    let kind: CompletionKind
    let isDirectory: Bool

    init(_ candidate: CompletionCandidate) {
        normalizedReplacement = candidate.replacementText
            .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        kind = candidate.kind
        isDirectory = candidate.isDirectory
    }
}

struct NormalizedCommand: Equatable, Hashable, Sendable {
    let full: String
    let executable: String?
    let commandKey: String?

    init(_ command: String) {
        let tokens = command.split(whereSeparator: \Character.isWhitespace).map(String.init)
        full = tokens.joined(separator: " ")
        executable = tokens.first
        guard let executable = tokens.first else { commandKey = nil; return }
        switch executable {
        case "git": commandKey = tokens.count > 1 ? tokens.prefix(2).joined(separator: " ") : executable
        case "npm": commandKey = tokens.count > 2 && tokens[1] == "run" ? tokens.prefix(3).joined(separator: " ") : tokens.prefix(2).joined(separator: " ")
        case "swift", "cargo": commandKey = tokens.prefix(2).joined(separator: " ")
        default: commandKey = executable
        }
    }
}

struct CommandUsageEvidence: Sendable { let lastUsedAt: Date; let firstUsedAt: Date; let totalCount: Int }
struct CommandAggregate: Sendable {
    let normalizedCommand: String; let commandKey: String; let projectID: String?; let directoryIdentity: String?
    let totalCount: Int; let successfulCount: Int; let failedCount: Int; let interruptedCount: Int
    let firstUsedAt: Date; let lastUsedAt: Date
    var successRate: Double? {
        let finished = successfulCount + failedCount
        return finished >= 3 ? min(1, max(0, Double(successfulCount) / Double(finished))) : nil
    }
}

struct CommandTransitionAggregate: Sendable {
    let previousCommandKey: String; let nextNormalizedCommand: String
    let projectID: String?; let directoryIdentity: String?
    let totalCount: Int; let successfulNextCount: Int; let lastObservedAt: Date
}

enum BehavioralCommandOutcome: Sendable, Equatable {
    case succeeded, failed, interrupted
}

struct BehavioralCommandRecord: Sendable {
    let eventID: UUID
    let normalizedCommand: String
    let commandKey: String
    let projectID: String?
    let directoryIdentity: String?
    let outcome: BehavioralCommandOutcome
    let observedAt: Date
}

enum CompletionFeedbackAction: String, Codable, Sendable { case accepted, partiallyAccepted, dismissed, replaced }
struct CompletionFeedbackRecord: Sendable {
    let candidateIdentity: String; let normalizedReplacement: String; let source: CompletionSource
    let supportingSources: Set<CompletionSource>; let projectID: String?; let directoryIdentity: String?
    let action: CompletionFeedbackAction; let rank: Int; let timestamp: Date
}

struct CompletionFeedbackAggregate: Sendable {
    let candidateIdentity: String
    let projectID: String?
    let directoryIdentity: String?
    let acceptanceCount: Int
    let dismissalCount: Int
    let replacementCount: Int
    let lastFeedbackAt: Date
}

protocol BehavioralCompletionStore: Sendable {
    func recordCommand(_ record: BehavioralCommandRecord) async throws
    func recordTransition(
        previousCommandKey: String,
        next: BehavioralCommandRecord
    ) async throws
    func commandAggregates(
        matchingPrefix prefix: String,
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CommandAggregate]
    func mostRecentCommands(
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CommandAggregate]
    func commandTransitions(
        after previousCommandKey: String,
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CommandTransitionAggregate]
    func recordFeedback(_ record: CompletionFeedbackRecord) async throws
    func feedbackAggregates(
        candidateIdentities: [String],
        projectID: String?,
        directoryIdentity: String?,
        limit: Int
    ) async throws -> [CompletionFeedbackAggregate]
}

struct HistoryCompletionProvider: CompletionProvider {
    let store: any BehavioralCompletionStore
    let identifier: CompletionProviderID = .history

    func candidates(for request: CompletionRequest) async throws -> [CompletionCandidate] {
        let draftLength = (request.draft as NSString).length
        guard !request.draft.isEmpty,
              request.cursorUTF16Offset == draftLength,
              !request.draft.contains(where: \.isNewline) else {
            return []
        }
        let prefix = NormalizedCommand(request.draft).full
        guard !prefix.isEmpty else { return [] }
        let aggregates = try await store.commandAggregates(
            matchingPrefix: prefix,
            projectID: request.projectContext?.identity,
            directoryIdentity: request.currentDirectory.standardizedFileURL.path,
            limit: min(100, max(0, request.maximumResults * 8))
        )
        return Self.mergedCandidates(
            aggregates,
            projectID: request.projectContext?.identity,
            directoryIdentity: request.currentDirectory.standardizedFileURL.path,
            replacementRange: NSRange(location: 0, length: draftLength),
            now: Date()
        )
    }

    private static func mergedCandidates(
        _ aggregates: [CommandAggregate],
        projectID: String?,
        directoryIdentity: String,
        replacementRange: NSRange,
        now: Date
    ) -> [CompletionCandidate] {
        var candidates: [String: CompletionCandidate] = [:]
        for aggregate in aggregates {
            var evidence = candidates[aggregate.normalizedCommand]?.evidence ?? CompletionEvidence()
            let age = max(0, now.timeIntervalSince(aggregate.lastUsedAt))
            if aggregate.projectID == nil, aggregate.directoryIdentity == nil {
                evidence.globalFrequency = max(evidence.globalFrequency, aggregate.totalCount)
                evidence.globalRecency = min(evidence.globalRecency ?? age, age)
            }
            if aggregate.projectID == projectID, aggregate.directoryIdentity == nil, projectID != nil {
                evidence.projectMatch = true
                evidence.projectFrequency = max(evidence.projectFrequency, aggregate.totalCount)
                evidence.projectRecency = min(evidence.projectRecency ?? age, age)
            }
            if aggregate.directoryIdentity == directoryIdentity {
                evidence.workingDirectoryMatch = true
                evidence.sessionFrequency = max(evidence.sessionFrequency, aggregate.totalCount)
                evidence.sessionRecency = min(evidence.sessionRecency ?? age, age)
            }
            if let successRate = aggregate.successRate {
                evidence.historicalSuccessRate = max(
                    evidence.historicalSuccessRate ?? 0,
                    successRate
                )
            }
            candidates[aggregate.normalizedCommand] = CompletionCandidate(
                id: "command:\(aggregate.normalizedCommand)",
                displayText: aggregate.normalizedCommand,
                replacementText: aggregate.normalizedCommand,
                replacementRange: replacementRange,
                source: .history,
                kind: .fullCommand,
                detail: "Command history",
                evidence: evidence
            )
        }
        return candidates.values.sorted {
            $0.replacementText.localizedStandardCompare($1.replacementText) == .orderedAscending
        }
    }
}

struct TransitionCompletionProvider: CompletionProvider {
    let store: any BehavioralCompletionStore
    let identifier: CompletionProviderID = .transition

    func candidates(for request: CompletionRequest) async throws -> [CompletionCandidate] {
        guard request.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let previous = request.previousCommand,
              Date().timeIntervalSince(previous.completedAt) <= 30 * 60 else {
            return []
        }
        let directory = request.currentDirectory.standardizedFileURL.path
        let transitions = try await store.commandTransitions(
            after: previous.commandKey,
            projectID: request.projectContext?.identity,
            directoryIdentity: directory,
            limit: 20
        )
        var selected: [String: CommandTransitionAggregate] = [:]
        for transition in transitions {
            let currentSpecificity = selected[transition.nextNormalizedCommand].map {
                Self.specificity($0, projectID: request.projectContext?.identity, directory: directory)
            } ?? -1
            let newSpecificity = Self.specificity(
                transition,
                projectID: request.projectContext?.identity,
                directory: directory
            )
            if newSpecificity > currentSpecificity {
                selected[transition.nextNormalizedCommand] = transition
            }
        }
        let scopedTransitions = Array(selected.values)
        let total = scopedTransitions.reduce(0) { $0 + $1.totalCount }
        guard total > 0 else { return [] }
        return scopedTransitions.compactMap { transition in
            let probability = Double(transition.totalCount) / Double(total)
            guard transition.totalCount >= 2,
                  probability >= 0.35 || transition.totalCount >= 5 else { return nil }
            var evidence = CompletionEvidence()
            evidence.transitionFrequency = transition.totalCount
            evidence.previousCommandMatch = true
            evidence.projectMatch = transition.projectID != nil
                && transition.projectID == request.projectContext?.identity
            evidence.workingDirectoryMatch = transition.directoryIdentity == directory
            evidence.projectRecency = max(0, Date().timeIntervalSince(transition.lastObservedAt))
            if transition.totalCount >= 3 {
                evidence.historicalSuccessRate = min(
                    1,
                    max(0, Double(transition.successfulNextCount) / Double(transition.totalCount))
                )
            }
            return CompletionCandidate(
                id: "next:\(transition.nextNormalizedCommand)",
                displayText: transition.nextNormalizedCommand,
                replacementText: transition.nextNormalizedCommand,
                replacementRange: request.tokenContext.replacementRange,
                source: .transition,
                kind: .nextCommand,
                detail: "Likely next command · used \(transition.totalCount) times",
                evidence: evidence
            )
        }
        .sorted { lhs, rhs in
            if lhs.evidence.transitionFrequency != rhs.evidence.transitionFrequency {
                return lhs.evidence.transitionFrequency > rhs.evidence.transitionFrequency
            }
            return lhs.replacementText.localizedStandardCompare(rhs.replacementText) == .orderedAscending
        }
        .prefix(3)
        .map { $0 }
    }

    private static func specificity(
        _ transition: CommandTransitionAggregate,
        projectID: String?,
        directory: String
    ) -> Int {
        if transition.directoryIdentity == directory { return 2 }
        if transition.projectID != nil, transition.projectID == projectID { return 1 }
        return 0
    }
}
