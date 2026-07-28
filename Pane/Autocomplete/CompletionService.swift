import Foundation

struct CompletionRequestID: Hashable, Sendable {
    let generation: UInt64
}

actor CompletionService {
    private enum ProviderEvent: Sendable {
        case local([CommandAutocompleteSuggestion])
        case zsh(ZshCompletionProtocol.Response?)
    }

    private let localProvider: LocalAutocompleteProvider
    private let autocomplete = CommandAutocomplete()
    private var generation: UInt64 = 0
    private var currentTask: Task<Void, Never>?

    init(localProvider: LocalAutocompleteProvider = LocalAutocompleteProvider()) {
        self.localProvider = localProvider
    }

    func suggestions(
        for context: LocalAutocompleteContext,
        zsh: @escaping @Sendable () async -> ZshCompletionProtocol.Response?,
        isValid: @escaping @MainActor @Sendable () -> Bool = { true }
    ) -> AsyncStream<[CommandAutocompleteSuggestion]> {
        generation &+= 1
        let requestID = CompletionRequestID(generation: generation)
        currentTask?.cancel()

        var streamContinuation: AsyncStream<[CommandAutocompleteSuggestion]>.Continuation!
        let stream = AsyncStream<[CommandAutocompleteSuggestion]> { continuation in
            streamContinuation = continuation
        }
        let autocomplete = self.autocomplete
        let task = Task { [weak self, localProvider] in
            defer { streamContinuation.finish() }
            await withTaskGroup(of: ProviderEvent.self) { group in
                group.addTask {
                    .local(await localProvider.suggestions(for: context))
                }
                group.addTask {
                    .zsh(await zsh())
                }

                var hasAuthoritativeZshResult = false
                while let event = await group.next() {
                    guard !Task.isCancelled,
                          await self?.isCurrent(requestID) == true,
                          await isValid() else {
                        group.cancelAll()
                        return
                    }

                    switch event {
                    case .local(let suggestions):
                        if !hasAuthoritativeZshResult {
                            streamContinuation.yield(suggestions)
                        }

                    case .zsh(let response):
                        // Any protocol-valid zsh response, including an empty
                        // one, is authoritative. If it wins the race, local
                        // work is cancelled without flashing heuristics first.
                        guard let response, response.status == .ok else {
                            continue
                        }
                        let candidates = autocomplete.capturedSuggestions(
                            response.candidates.map {
                                ZshCompletionCandidate(
                                    replacementText: $0.replacementText,
                                    detail: $0.detail,
                                    isDirectory: $0.isDirectory
                                )
                            }
                        )
                        hasAuthoritativeZshResult = true
                        streamContinuation.yield(candidates)
                        group.cancelAll()
                    }
                }
            }
        }
        currentTask = task
        streamContinuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func isCurrent(_ requestID: CompletionRequestID) -> Bool {
        requestID.generation == generation
    }
}
