import Foundation

struct CompletionRequestID: Hashable, Sendable { let generation: UInt64 }

actor CompletionService {
    private struct ProviderResult: Sendable {
        let id: CompletionProviderID
        let candidates: [CompletionCandidate]
        let diagnostic: CompletionProviderDiagnostic
    }

    private let localProvider: LocalAutocompleteProvider
    private let autocomplete = CommandAutocomplete()
    private let ranker = CompletionRanker()
    private var generation: UInt64 = 0
    private var currentTask: Task<Void, Never>?
#if DEBUG
    private var debugRequestID: UUID?
    private var debugInFlight: Set<CompletionProviderID> = []
    private var debugDiagnostics: [CompletionProviderDiagnostic] = []
    private var debugRawCount = 0
    private var debugMergedCount = 0
    private var debugPublishedCount = 0
    private var debugStaleCount = 0
    private var debugTimeoutCount = 0
    private var debugRankingDuration: Duration?
    private var debugProjectID: String?
#endif

    init(localProvider: LocalAutocompleteProvider = LocalAutocompleteProvider()) {
        self.localProvider = localProvider
    }

    func commandDidComplete(_ command: String) async {
        guard NormalizedCommand(command).executable == "git" else { return }
        await localProvider.invalidateGitContext()
    }

    func shellDidRestart() async {
        await localProvider.invalidateProjectContext()
    }

    func projectDefinition(for directory: URL) async -> ProjectContext? {
        await localProvider.projectDefinition(for: directory)
    }

    func projectContext(for directory: URL) async -> ProjectContext? {
        await localProvider.projectContext(for: directory)
    }

    /// Compatibility surface used by the composer. Unlike P0, zsh is another
    /// contributor: it can improve the result but cannot erase local evidence.
    func suggestions(for context: LocalAutocompleteContext,
                     zsh: @escaping @Sendable () async -> ZshCompletionProtocol.Response?,
                     behavioralStore: (any BehavioralCompletionStore)? = nil,
                     previousCommand: CompletedCommandSummary? = nil,
                     projectContext: ProjectContext? = nil,
                     isValid: @escaping @MainActor @Sendable () -> Bool = { true })
        -> AsyncStream<[CommandAutocompleteSuggestion]> {
        generation &+= 1
        let requestID = CompletionRequestID(generation: generation)
        let tokenRange = autocomplete.replacementRange(
            in: context.draft,
            cursorUTF16Offset: context.cursorUTF16Offset
        )
        let nativeRequest = CompletionRequest(
            id: UUID(),
            generation: generation,
            draft: context.draft,
            cursorUTF16Offset: context.cursorUTF16Offset,
            tokenContext: CommandTokenContext(
                replacementRange: tokenRange,
                decodedPrefix: autocomplete.decodedPrefix(
                    in: context.draft,
                    cursorUTF16Offset: context.cursorUTF16Offset
                ),
                isCommandPosition: true
            ),
            currentDirectory: context.currentDirectory,
            projectContext: projectContext,
            previousCommand: previousCommand,
            executableSearchPath: context.executableSearchPath,
            shellGeneration: context.shellGeneration,
            maximumResults: 12,
            createdAt: ContinuousClock.now
        )
        currentTask?.cancel()
        var continuation: AsyncStream<[CommandAutocompleteSuggestion]>.Continuation!
        let stream = AsyncStream<[CommandAutocompleteSuggestion]> { continuation = $0 }
        let task = Task { [weak self, localProvider, autocomplete, ranker] in
            defer { continuation.finish() }
            await withTaskGroup(of: [CompletionCandidate]?.self) { group in
                group.addTask {
                    // This compatibility provider still combines cached local,
                    // filesystem, executable, and project discovery work.
                    // Its components receive independent budgets in the
                    // provider-native API; timing out the combined adapter can
                    // otherwise erase the only useful fallback result.
                    return await localProvider.suggestions(for: context).map {
                        Self.candidate($0)
                    }
                }
                group.addTask {
                    let response = try? await withTimeout(.milliseconds(200)) { await zsh() }
                    guard let response = response ?? nil, response.status == .ok else { return nil }
                    return autocomplete.capturedSuggestions(response.candidates.map {
                        ZshCompletionCandidate(replacementText: $0.replacementText,
                                               detail: $0.detail, isDirectory: $0.isDirectory)
                    }).map {
                        Self.candidate($0, fallbackRange: tokenRange)
                    }
                }
                if let behavioralStore {
                    group.addTask {
                        try? await withTimeout(.milliseconds(75)) {
                            try await HistoryCompletionProvider(store: behavioralStore)
                                .candidates(for: nativeRequest)
                        }
                    }
                    if previousCommand != nil {
                        group.addTask {
                            try? await withTimeout(.milliseconds(75)) {
                                try await TransitionCompletionProvider(store: behavioralStore)
                                    .candidates(for: nativeRequest)
                            }
                        }
                    }
                }
                var accumulated: [CompletionCandidate] = []
                var lastIDs: [String] = []
                while let result = await group.next() {
                    guard !Task.isCancelled, await self?.isCurrent(requestID) == true,
                          await isValid() else { group.cancelAll(); return }
                    guard let result else { continue }
                    accumulated.append(contentsOf: result)
                    let enriched = await Self.enrich(
                        accumulated,
                        using: behavioralStore,
                        request: nativeRequest
                    )
                    let ranked = ranker.rank(enriched, maximumResults: 12)
                        .map(Self.suggestion)
                    let ids = ranked.map { Self.stableIdentity($0) }
                    guard ids != lastIDs else { continue }
                    lastIDs = ids
                    continuation.yield(ranked)
                }
            }
        }
        currentTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Provider-native staged response API. Each completed provider is merged,
    /// ranked and published while late results are protected by request identity.
    func responses(for request: CompletionRequest,
                   providers: [any CompletionProvider],
                   budgets: [CompletionProviderID: Duration] = [:],
                   isValid: @escaping @Sendable () async -> Bool = { true })
        -> AsyncStream<CompletionResponse> {
        generation = max(generation &+ 1, request.generation)
        let activeGeneration = generation
#if DEBUG
        debugRequestID = request.id
        debugInFlight = Set(providers.map(\.identifier))
        debugDiagnostics = []
        debugRawCount = 0
        debugMergedCount = 0
        debugPublishedCount = 0
        debugRankingDuration = nil
        debugProjectID = request.projectContext?.identity
#endif
        currentTask?.cancel()
        var continuation: AsyncStream<CompletionResponse>.Continuation!
        let stream = AsyncStream<CompletionResponse> { continuation = $0 }
        let task = Task { [weak self, ranker] in
            defer { continuation.finish() }
            let clock = ContinuousClock(); let started = clock.now
            await withTaskGroup(of: ProviderResult.self) { group in
                for provider in providers {
                    group.addTask {
                        await Self.run(provider, request: request,
                                       budget: budgets[provider.identifier] ?? Self.defaultBudget(provider.identifier))
                    }
                }
                var all: [CompletionCandidate] = []; var diagnostics: [CompletionProviderDiagnostic] = []
                var lastIDs: [String] = []; var remaining = providers.count
                while let result = await group.next() {
                    remaining -= 1
#if DEBUG
                    await self?.recordDiagnostic(result.diagnostic)
#endif
                    guard !Task.isCancelled, await self?.generation == activeGeneration,
                          request.generation == activeGeneration, await isValid() else {
#if DEBUG
                        await self?.recordStaleResponse()
#endif
                        group.cancelAll(); return
                    }
                    all.append(contentsOf: result.candidates.prefix(Self.maximumRaw(result.id)))
                    if all.count > 500 { all = Array(all.prefix(500)) }
                    diagnostics.append(result.diagnostic)
                    let ranked = ranker.rank(all, maximumResults: min(12, max(0, request.maximumResults)))
#if DEBUG
                    await self?.recordRanking(
                        rawCount: all.count,
                        mergedCount: ranker.deduplicate(all).count,
                        publishedCount: ranked.count,
                        duration: started.duration(to: clock.now)
                    )
#endif
                    let ids = ranked.map(\.id)
                    // A final diagnostic-only response is allowed even when
                    // its candidate IDs match the prior staged response.
                    guard ids != lastIDs || remaining == 0 else { continue }
                    lastIDs = ids
                    continuation.yield(CompletionResponse(requestID: request.id,
                        generation: request.generation, candidates: ranked,
                        elapsed: started.duration(to: clock.now), diagnostics: diagnostics,
                        isFinal: remaining == 0))
                }
            }
        }
        currentTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func run(_ provider: any CompletionProvider, request: CompletionRequest,
                            budget: Duration) async -> ProviderResult {
        let clock = ContinuousClock(); let start = clock.now
        do {
            let candidates = try await withTimeout(budget) { try await provider.candidates(for: request) }
            return ProviderResult(id: provider.identifier, candidates: candidates,
                diagnostic: .init(provider: provider.identifier, elapsed: start.duration(to: clock.now),
                    candidateCount: candidates.count, cacheHit: false, timedOut: false,
                    cancelled: false, errorCategory: nil))
        } catch CompletionProviderError.timedOut {
            return ProviderResult(id: provider.identifier, candidates: [],
                diagnostic: .init(provider: provider.identifier, elapsed: start.duration(to: clock.now),
                    candidateCount: 0, cacheHit: false, timedOut: true,
                    cancelled: false, errorCategory: "timeout"))
        } catch {
            return ProviderResult(id: provider.identifier, candidates: [],
                diagnostic: .init(provider: provider.identifier, elapsed: start.duration(to: clock.now),
                    candidateCount: 0, cacheHit: false, timedOut: false,
                    cancelled: error is CancellationError, errorCategory: "provider"))
        }
    }

    private static func defaultBudget(_ id: CompletionProviderID) -> Duration {
        switch id { case .local: return .milliseconds(50); case .history, .transition: return .milliseconds(75)
        case .project: return .milliseconds(100); case .zsh: return .milliseconds(200) }
    }
    private static func maximumRaw(_ id: CompletionProviderID) -> Int {
        switch id { case .local: return 200; case .zsh: return 300; case .history, .project: return 100; case .transition: return 20 }
    }
    private func isCurrent(_ id: CompletionRequestID) -> Bool { id.generation == generation }

    private static func candidate(
        _ suggestion: CommandAutocompleteSuggestion,
        fallbackRange: NSRange? = nil
    ) -> CompletionCandidate {
        let source: CompletionSource
        let kind: CompletionKind
        switch suggestion.source {
        case .zsh: source = .zsh; kind = .argument
        case .history: source = .history; kind = .fullCommand
        case .builtIn: source = .builtIn; kind = .command
        case .executable: source = .executable; kind = .command
        case .fileSystem: source = .fileSystem; kind = .path
        case .projectScript: source = .projectScript; kind = .fullCommand
        case .transition: source = .transition; kind = .nextCommand
        }
        return CompletionCandidate(displayText: suggestion.text, replacementText: suggestion.replacementText,
            replacementRange: suggestion.replacementRange ?? fallbackRange,
            source: source, kind: kind, detail: suggestion.detail, isDirectory: suggestion.isDirectory)
    }
    private static func suggestion(_ ranked: RankedCompletion) -> CommandAutocompleteSuggestion {
        let c = ranked.candidate
        let source: CommandAutocompleteSuggestion.Source
        switch c.source { case .zsh: source = .zsh; case .history: source = .history
        case .transition: source = .transition
        case .builtIn: source = .builtIn; case .executable: source = .executable
        case .fileSystem: source = .fileSystem; case .projectScript, .projectCommand: source = .projectScript }
        return .init(text: c.displayText, replacementText: c.replacementText,
                     replacementRange: c.replacementRange, source: source,
                     isDirectory: c.isDirectory, detail: c.detail)
    }
    private static func stableIdentity(_ value: CommandAutocompleteSuggestion) -> String {
        "\(value.replacementText)|\(value.isDirectory)"
    }

#if DEBUG
    func debugSnapshot() -> CompletionDebugSnapshot {
        CompletionDebugSnapshot(
            requestID: debugRequestID,
            generation: generation,
            inFlightProviders: debugInFlight,
            lastDiagnostics: debugDiagnostics,
            rawCandidateCount: debugRawCount,
            mergedCandidateCount: debugMergedCount,
            publishedCandidateCount: debugPublishedCount,
            staleResponseCount: debugStaleCount,
            timeoutCount: debugTimeoutCount,
            rankingDuration: debugRankingDuration,
            projectID: debugProjectID
        )
    }

    private func recordDiagnostic(_ diagnostic: CompletionProviderDiagnostic) {
        debugInFlight.remove(diagnostic.provider)
        debugDiagnostics.append(diagnostic)
        if diagnostic.timedOut { debugTimeoutCount += 1 }
    }

    private func recordStaleResponse() {
        debugStaleCount += 1
    }

    private func recordRanking(
        rawCount: Int,
        mergedCount: Int,
        publishedCount: Int,
        duration: Duration
    ) {
        debugRawCount = rawCount
        debugMergedCount = mergedCount
        debugPublishedCount = publishedCount
        debugRankingDuration = duration
    }
#endif

    private static func enrich(
        _ candidates: [CompletionCandidate],
        using store: (any BehavioralCompletionStore)?,
        request: CompletionRequest
    ) async -> [CompletionCandidate] {
        guard let store, !candidates.isEmpty else { return candidates }
        let identities = candidates.map {
            "\(CompletionCandidateIdentity($0).kind.rawValue)|\($0.isDirectory)|\(CompletionCandidateIdentity($0).normalizedReplacement)"
        }
        guard let aggregates = try? await store.feedbackAggregates(
            candidateIdentities: identities,
            projectID: request.projectContext?.identity,
            directoryIdentity: request.currentDirectory.standardizedFileURL.path,
            limit: min(500, identities.count * 3)
        ) else { return candidates }
        let grouped = Dictionary(grouping: aggregates, by: \.candidateIdentity)
        return candidates.map { candidate in
            var candidate = candidate
            let identity = CompletionCandidateIdentity(candidate)
            let key = "\(identity.kind.rawValue)|\(candidate.isDirectory)|\(identity.normalizedReplacement)"
            for feedback in grouped[key] ?? [] {
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
