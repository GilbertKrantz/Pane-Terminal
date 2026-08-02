import Foundation

@MainActor
extension TerminalSession {
    func autocompleteSuggestions(
        for draft: String,
        cursorUTF16Offset: Int
    ) async -> AsyncStream<[CommandAutocompleteSuggestion]> {
        guard terminalSecurityState.inputMode == .normal,
              mode == .blocks,
              isShellRunning,
              isShellIntegrationReady,
              !isCommandActive,
              !isAlternateScreenActive,
              terminalView?.terminal.isCurrentBufferAlternate != true,
              let endpoint = zshCompletionEndpoint,
              endpoint.generation == processGeneration else {
            return AsyncStream { $0.finish() }
        }

        let directory = URL(
            fileURLWithPath: currentDirectory ?? shellConfiguration.workingDirectory,
            isDirectory: true
        )
        let generation = processGeneration
        let projectContext = await completionService.projectDefinition(for: directory)
        if let runtimeStateController {
            _ = await runtimeStateController.updateCurrentProjectIdentity(projectContext?.identity)
        }
        let context = LocalAutocompleteContext(
            draft: draft,
            cursorUTF16Offset: cursorUTF16Offset,
            history: history.commands,
            currentDirectory: directory,
            executableSearchPath: shellEnvironmentValue(named: "PATH") ?? "",
            shellGeneration: generation
        )
        return await completionService.suggestions(
            for: context,
            zsh: { [zshCompletionClient] in
                await zshCompletionClient.completions(
                    for: draft,
                    cursorUTF16Offset: cursorUTF16Offset,
                    endpoint: endpoint
                )
            },
            behavioralStore: runtimeStateController,
            previousCommand: previousCompletedCommandSummary,
            projectContext: projectContext,
            isValid: { [weak self] in
                guard let self else { return false }
                return self.mode == .blocks
                    && self.processGeneration == generation
                    && self.zshCompletionEndpoint == endpoint
                    && !self.isCommandActive
                    && !self.isAlternateScreenActive
                    && self.terminalSecurityState.inputMode == .normal
            }
        )
    }

    func composerProjectContext(
        for directory: URL,
        reason: ContextRefreshReason = .tabSelected
    ) async -> ProjectContext? {
        await completionService.projectContext(
            for: directory,
            visibility: visibilityState,
            reason: reason
        )
    }

    func refreshComposerContext() async {
        await completionService.invalidateProjectContext()
        composerContextGeneration &+= 1
    }

    var canSuggestNextCommand: Bool {
        previousCompletedCommandSummary != nil
            && !isCommandActive
            && terminalSecurityState.inputMode == .normal
            && interactionController.state == .shellIdle
    }

    func recordCompletionFeedback(
        for suggestion: CommandAutocompleteSuggestion,
        action: CompletionFeedbackAction,
        rank: Int
    ) {
        guard !isSecureInputActive, let runtimeStateController else { return }
        let source = CompletionSourceMapping.candidateSource(from: suggestion.source)
        let supportingSources = Set(suggestion.supportingSources.map {
            CompletionSourceMapping.candidateSource(from: $0)
        })
        let record = CompletionFeedbackRecord(
            candidateIdentity: suggestion.id,
            normalizedReplacement: suggestion.replacementText,
            source: source,
            supportingSources: supportingSources,
            projectID: nil,
            directoryIdentity: currentDirectory ?? shellConfiguration.workingDirectory,
            action: action,
            rank: max(0, rank),
            timestamp: Date()
        )
        Task { [weak self] in
            if let diagnostic = await runtimeStateController.recordCompletionFeedback(record) {
                self?.runtimeStateDiagnostic = diagnostic
            }
        }
    }
}
