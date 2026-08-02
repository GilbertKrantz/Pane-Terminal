import Foundation

@MainActor
extension TerminalSession {
    func startShell(in workingDirectory: String? = nil) {
        guard !isShuttingDown, !ptyController.isRunning else { return }
        _ = interactionController.handle(.shellStarted)
        shellReadiness = .starting
        guard isRuntimeStatePrepared else {
            prepareRuntimeStateAndStartShell()
            return
        }

        shellExitStatus = nil
        streamParser = BlockStreamParser()
        transcriptFilter = AlternateScreenTranscriptFilter()
        let effectiveDirectory = Self.validatedWorkingDirectory(workingDirectory)
            ?? Self.validatedWorkingDirectory(currentDirectory)
            ?? Self.validatedWorkingDirectory(shellConfiguration.workingDirectory)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        currentDirectory = effectiveDirectory
        let startResult = ptyController.start(
            configuration: shellConfiguration,
            workingDirectory: effectiveDirectory
        )
        let generation = startResult.generation
        let completionEndpoint = try? zshCompletionClient.makeEndpoint(
            for: generation
        )
        zshCompletionEndpoint = completionEndpoint
        isShellRunning = startResult.isRunning

        if startResult.isRunning {
            Task {
                await PaneLifecycleEventRing.shared.append(PaneLifecycleEvent(
                    timestamp: Date(),
                    kind: .ptyStarted,
                    tabID: tabID,
                    sessionID: sessionID,
                    outcome: .succeeded
                ))
            }
            shellReadiness = .initializing
            startForegroundProcessMonitoring()
            let installationCommand: String
            if let completionEndpoint {
                installationCommand = ShellIntegration.installationCommand(
                    completionSocketPath: completionEndpoint.socketPath
                )
            } else {
                installationCommand = ShellIntegration.installationCommand
            }
            _ = ptyController.write(
                CommandSerializer.serializeCommand(installationCommand)
            )
        } else {
            shellReadiness = .stopped
            _ = interactionController.handle(.shellExited)
            invalidateCompletionEndpoint()
            terminalView?.feed(text: "\r\n[Unable to start \(shellConfiguration.executable)]\r\n")
        }
    }

    func restartShell() {
        guard restartTask == nil, !isShuttingDown else { return }
        lifecycleFaultCheckpointHandler?(.shellRestartRequested)
        _ = interactionController.handle(.restartRequested)
        isRestartInProgress = true
        shellReadiness = .starting
        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.restartTask = nil
                self.isRestartInProgress = false
            }
            await self.finalizeUnfinishedCommand(reason: .shellRestart)
            self.lifecycleFaultCheckpointHandler?(.shellRestartCommandFinalized)
            await self.runtimeStateController?.resetBehavioralTransitionContinuity()
            self.previousCompletedCommandSummary = nil
            await self.completionService.shellDidRestart()
            self.composerContextGeneration &+= 1
            self.isShellRunning = false
            _ = await self.ptyController.terminateAndWait()
            self.lifecycleFaultCheckpointHandler?(.shellRestartPTYTerminated)
            self.invalidateCompletionEndpoint()
            self.stopForegroundProcessMonitoring()
            self.leaveAlternateScreenIfNeeded()
            self.terminalView?.feed(text: "\r\n[Restarting shell]\r\n")
            self.lastShellRestartAt = Date()
            await PaneLifecycleEventRing.shared.append(PaneLifecycleEvent(
                timestamp: Date(),
                kind: .shellRestarted,
                tabID: self.tabID,
                sessionID: self.sessionID,
                outcome: .succeeded
            ))
            self.lifecycleFaultCheckpointHandler?(.shellRestartStartingReplacement)
            self.startShell()
        }
    }

    func requestRestartShell() {
        if isCommandActive {
            isRestartConfirmationPresented = true
        } else {
            restartShell()
        }
    }

    func confirmRestartShell() {
        isRestartConfirmationPresented = false
        restartShell()
    }

    func shutdown() {
        guard shutdownTask == nil, completedShutdownResult == nil else { return }
        shutdownTask = makeShutdownTask(reason: .controlledShutdown)
    }

    @discardableResult
    func shutdownAndWait() async -> SessionShutdownResult {
        if let completedShutdownResult {
            return completedShutdownResult
        }
        if let shutdownTask {
            return await shutdownTask.value
        }
        let task = makeShutdownTask(reason: .controlledShutdown)
        shutdownTask = task
        return await task.value
    }

    private func makeShutdownTask(
        reason: CommandInterruptionReason
    ) -> Task<SessionShutdownResult, Never> {
        _ = interactionController.handle(.applicationClosing)
        isShuttingDown = true
        requestFocus(.none)
        blockSearchFocusGeneration &+= 1
        composerContextGeneration &+= 1
#if DEBUG
        lifecycleLog("shutdown started")
#endif
        cancelOwnedWorkForShutdown()
        let pendingSearch = blockSearchTask
        blockSearchTask?.cancel()
        blockSearchTask = nil
        let hadUnfinishedCommand = blockLifecycleController.activeOrAwaitingBlockID != nil
        let renderedOutputAtShutdown = renderedActiveBlockOutput()
        prepareProcessForShutdown()
        let processTerminationTask = ptyController.startTermination()

        return Task { @MainActor in
            await PaneLifecycleEventRing.shared.append(PaneLifecycleEvent(
                timestamp: Date(),
                kind: .sessionClosing,
                tabID: tabID,
                sessionID: sessionID,
                outcome: .requested
            ))
            _ = await blockSearchIndex.cancelPendingSearches()
            await pendingSearch?.value
            await finalizeUnfinishedCommand(
                reason: reason,
                renderedOutput: renderedOutputAtShutdown
            )
            _ = await runtimeStateController?.closeCurrentSessionCleanly()
            await completionService.cancelPendingRequests()
            let processTermination = await processTerminationTask.value
            let result = SessionShutdownResult(
                sessionID: sessionID,
                processTermination: processTermination,
                unfinishedCommandFinalized: hadUnfinishedCommand
            )
            completedShutdownResult = result
            shutdownTask = nil
#if DEBUG
            debugShutdownCompleted = true
            lifecycleLog("shutdown completed")
#endif
            await PaneLifecycleEventRing.shared.append(PaneLifecycleEvent(
                timestamp: Date(),
                kind: .sessionClosed,
                tabID: tabID,
                sessionID: sessionID,
                outcome: processTermination.outcome == .timedOut ? .timedOut : .succeeded
            ))
            return result
        }
    }

    private func cancelOwnedWorkForShutdown() {
        restartTask?.cancel()
        restartTask = nil
        runtimeStateStartTask?.cancel()
        runtimeStateStartTask = nil
        onMeaningfulBackgroundOutput = nil
    }

    private func prepareProcessForShutdown() {
        isShellRunning = false
        shellReadiness = .stopped
        invalidateCompletionEndpoint()
        stopForegroundProcessMonitoring()
        zshCompletionClient.shutdown()
        ptyController.onEvent = nil
        terminalView?.terminalDelegate = nil
        if let paneTerminalView = terminalView as? PaneTerminalView {
            paneTerminalView.onAlternateScreenChanged = nil
            paneTerminalView.onTerminalResponse = nil
        }
        liveCommandTerminalView = nil
        authoritativeTerminalHostView = nil
        terminalView = nil
    }

    /// App termination does not need to repaint status into a disappearing
    /// SwiftUI hierarchy. The PTY controller invalidates the active generation
    /// before terminating it, so a later process callback is a no-op.
    func terminateForApplicationExit() {
        guard shutdownTask == nil, completedShutdownResult == nil else { return }
        shutdownTask = makeShutdownTask(reason: .applicationExit)
    }

    func finalizeApplicationExit() async {
        guard !isApplicationExitFinalized else { return }
        isApplicationExitFinalized = true
        if completedShutdownResult != nil {
            return
        }
        if let shutdownTask {
            _ = await shutdownTask.value
            return
        }
        let task = makeShutdownTask(reason: .applicationExit)
        shutdownTask = task
        _ = await task.value
    }


#if DEBUG
    var debugHasProcessReference: Bool { ptyController.debugHasProcessReference }

    func lifecycleLog(_ event: String) {
        print("Pane lifecycle session[\(lifecycleDebugID.uuidString)] \(event)")
    }
#endif
}
