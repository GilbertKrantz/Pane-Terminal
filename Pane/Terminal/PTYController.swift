import Darwin
import Foundation
@preconcurrency import SwiftTerm

struct PTYForegroundStatus: Equatable, Sendable {
    let processGroupID: pid_t
    let shellProcessGroupID: pid_t?
    let isRawInput: Bool
    let echoEnabled: Bool
}

struct PTYTerminationResult: Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case notRunning
        case terminated
        case killed
        case timedOut
    }

    let processID: pid_t?
    let outcome: Outcome
    let elapsed: Duration
}

@MainActor
protocol PTYProcessDriving: AnyObject {
    var running: Bool { get }
    var childFileDescriptor: Int32 { get }
    var shellProcessID: pid_t { get }

    func start(configuration: ShellConfiguration, workingDirectory: String)
    func send(_ data: ArraySlice<UInt8>)
    func terminate()
}

private final class SwiftTermPTYProcessDriver: PTYProcessDriving {
    private let process: LocalProcess

    init(delegate: LocalProcessDelegate) {
        process = LocalProcess(delegate: delegate, dispatchQueue: .main)
    }

    var running: Bool { process.running }
    var childFileDescriptor: Int32 { process.childfd }
    var shellProcessID: pid_t { process.shellPid }

    func start(configuration: ShellConfiguration, workingDirectory: String) {
        process.startProcess(
            executable: configuration.executable,
            args: configuration.arguments,
            environment: configuration.environment,
            currentDirectory: workingDirectory
        )
    }

    func send(_ data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func terminate() {
        process.terminate()
    }
}

/// SwiftTerm does not identify the source process for data callbacks. Each
/// shell generation receives its own delegate so delayed callbacks can be
/// rejected before they reach the renderer or transcript pipeline.
private final class PTYProcessDelegateBridge: LocalProcessDelegate {
    let generation: UInt64
    private let dataHandler: ([UInt8], UInt64) -> Void
    private let terminationHandler: (Int32?, UInt64) -> Void
    private let windowSizeProvider: () -> winsize

    init(
        generation: UInt64,
        dataHandler: @escaping ([UInt8], UInt64) -> Void,
        terminationHandler: @escaping (Int32?, UInt64) -> Void,
        windowSizeProvider: @escaping () -> winsize
    ) {
        self.generation = generation
        self.dataHandler = dataHandler
        self.terminationHandler = terminationHandler
        self.windowSizeProvider = windowSizeProvider
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        dataHandler(Array(slice), generation)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        terminationHandler(exitCode, generation)
    }

    func getWindowSize() -> winsize {
        windowSizeProvider()
    }
}

@MainActor
final class PTYController {
    enum Event: Equatable, Sendable {
        case received(Data)
        case terminated(waitStatus: Int32?)
    }

    struct StartResult: Equatable, Sendable {
        let generation: UInt64
        let isRunning: Bool
    }

    typealias ProcessFactory = (LocalProcessDelegate) -> any PTYProcessDriving
    typealias ResizeHandler = (Int32, inout winsize) -> Void

    var onEvent: ((Event) -> Void)?

    private(set) var generation: UInt64 = 0
    private(set) var windowSize: winsize

    private var process: (any PTYProcessDriving)?
    private var processBridge: PTYProcessDelegateBridge?
    private var countsRunningPTY = false
    private var generationGate = PTYGenerationGate()
    private let processFactory: ProcessFactory
    private let resizeHandler: ResizeHandler
    private let terminationDelay: DispatchTimeInterval
#if DEBUG
    private let debugID = UUID()
#endif

    init(
        initialWindowSize: winsize = winsize(
            ws_row: 25,
            ws_col: 80,
            ws_xpixel: 0,
            ws_ypixel: 0
        ),
        terminationDelay: DispatchTimeInterval = .milliseconds(40),
        processFactory: ProcessFactory? = nil,
        resizeHandler: ResizeHandler? = nil
    ) {
        windowSize = initialWindowSize
        self.terminationDelay = terminationDelay
        self.processFactory = processFactory ?? {
            SwiftTermPTYProcessDriver(delegate: $0)
        }
        self.resizeHandler = resizeHandler ?? { descriptor, size in
            _ = PseudoTerminalHelpers.setWinSize(
                masterPtyDescriptor: descriptor,
                windowSize: &size
            )
        }
        PaneResourceCounters.increment(.ptyController)
    }

    deinit {
        PaneResourceCounters.decrement(.ptyController)
    }

    var isRunning: Bool {
        process?.running == true
    }

    func start(
        configuration: ShellConfiguration,
        workingDirectory: String
    ) -> StartResult {
        terminate()

        let nextGeneration = generationGate.beginReplacement()
        generation = nextGeneration
        let bridge = PTYProcessDelegateBridge(
            generation: nextGeneration,
            dataHandler: { [weak self] bytes, generation in
                assert(Thread.isMainThread)
                MainActor.assumeIsolated {
                    self?.receive(bytes, from: generation)
                }
            },
            terminationHandler: { [weak self] waitStatus, generation in
                assert(Thread.isMainThread)
                MainActor.assumeIsolated {
                    self?.scheduleTermination(
                        waitStatus: waitStatus,
                        generation: generation
                    )
                }
            },
            windowSizeProvider: { [weak self] in
                assert(Thread.isMainThread)
                return MainActor.assumeIsolated {
                    self?.windowSize
                        ?? winsize(ws_row: 25, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
                }
            }
        )
        let newProcess = processFactory(bridge)
        processBridge = bridge
        process = newProcess
        newProcess.start(
            configuration: configuration,
            workingDirectory: workingDirectory
        )

#if DEBUG
        Self.lifecycleLog("process started", id: debugID, detail: "generation=\(nextGeneration)")
#endif

        let running = newProcess.running
        if !running {
            process = nil
            processBridge = nil
            _ = generationGate.acceptTermination(from: nextGeneration)
        } else {
            countsRunningPTY = true
            PaneResourceCounters.increment(.runningPTY)
        }
        return StartResult(generation: nextGeneration, isRunning: running)
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        guard let process, process.running else { return false }
        process.send(bytes[...])
        return true
    }

    @discardableResult
    func resize(to newSize: winsize) -> Bool {
        guard !Self.equalWindowSizes(windowSize, newSize) else { return false }
        windowSize = newSize

        guard let process,
              process.running,
              process.childFileDescriptor >= 0 else { return true }
        var requestedSize = newSize
        resizeHandler(process.childFileDescriptor, &requestedSize)
        return true
    }

    func interrupt() {
        _ = write([0x03])
    }

    func terminate() {
        _ = startTermination()
    }

    /// Detaches the active process synchronously so callers can release their
    /// PTY references before awaiting bounded process reaping.
    func startTermination(
        gracefulWait: Duration = .seconds(1),
        killWait: Duration = .milliseconds(500)
    ) -> Task<PTYTerminationResult, Never> {
        guard let termination = detachCurrentProcess() else {
            return Task {
                PTYTerminationResult(
                    processID: nil,
                    outcome: .notRunning,
                    elapsed: .zero
                )
            }
        }
        Self.signalProcessGroups(termination.identity, signal: SIGTERM)
        termination.process.terminate()
#if DEBUG
        let lifecycleDebugID = debugID
        Self.lifecycleLog(
            "process termination requested",
            id: lifecycleDebugID,
            detail: "pid=\(termination.identity.processID)"
        )
#endif
        let debugProcessID = termination.identity.processID
        return Task.detached(priority: .utility) {
            let result = await Self.reapBounded(
                termination.identity,
                gracefulWait: gracefulWait,
                killWait: killWait
            )
#if DEBUG
            Self.lifecycleLog(
                "process terminated",
                id: lifecycleDebugID,
                detail: "pid=\(debugProcessID) outcome=\(result.outcome.rawValue)"
            )
#endif
            return result
        }
    }

    func terminateAndWait(
        gracefulWait: Duration = .seconds(1),
        killWait: Duration = .milliseconds(500)
    ) async -> PTYTerminationResult {
        guard process != nil else {
            return PTYTerminationResult(
                processID: nil,
                outcome: .notRunning,
                elapsed: .zero
            )
        }
        return await startTermination(
            gracefulWait: gracefulWait,
            killWait: killWait
        ).value
    }

    func foregroundStatus() -> PTYForegroundStatus? {
        guard let process,
              process.running,
              process.childFileDescriptor >= 0 else { return nil }
        let descriptor = process.childFileDescriptor
        let foregroundPGID = tcgetpgrp(descriptor)
        guard foregroundPGID > 0 else { return nil }

        var termiosState = termios()
        let hasTermios = tcgetattr(descriptor, &termiosState) == 0
        let localFlags = hasTermios ? termiosState.c_lflag : 0
        let echoEnabled = !hasTermios || (localFlags & tcflag_t(ECHO) != 0)
        // ECHO and ICANON are independent. Password prompts commonly clear
        // only ECHO, while REPLs and full-screen applications use
        // non-canonical input (and often clear ECHO as part of raw mode).
        // Conflating the two classifies ordinary interactive applications as
        // secure input and steals their direct-input routing.
        let isRawInput = hasTermios
            && localFlags & tcflag_t(ICANON) == 0
        let shellPID = process.shellProcessID
        let shellPGID = shellPID > 0 ? getpgid(shellPID) : -1

        return PTYForegroundStatus(
            processGroupID: foregroundPGID,
            shellProcessGroupID: shellPGID > 0 ? shellPGID : nil,
            isRawInput: isRawInput,
            echoEnabled: echoEnabled
        )
    }

    private func receive(_ bytes: [UInt8], from generation: UInt64) {
        guard generationGate.acceptsOutput(from: generation), process != nil else { return }
        onEvent?(.received(Data(bytes)))
    }

    private func scheduleTermination(waitStatus: Int32?, generation: UInt64) {
        if case .nanoseconds(0) = terminationDelay {
            acceptTermination(waitStatus: waitStatus, generation: generation)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + terminationDelay) { [weak self] in
            self?.acceptTermination(waitStatus: waitStatus, generation: generation)
        }
    }

    private func acceptTermination(waitStatus: Int32?, generation: UInt64) {
        guard generationGate.acceptTermination(from: generation) else { return }
        process = nil
        processBridge = nil
        releaseRunningPTYCount()
#if DEBUG
        Self.lifecycleLog("process terminated", id: debugID, detail: "generation=\(generation)")
#endif
        onEvent?(.terminated(waitStatus: waitStatus))
    }

    private struct ProcessIdentity: Sendable {
        let processID: pid_t
        let shellProcessGroupID: pid_t?
        let foregroundProcessGroupID: pid_t?
    }

    private func detachCurrentProcess() -> (
        process: any PTYProcessDriving,
        identity: ProcessIdentity
    )? {
        guard let oldProcess = process else { return nil }
        let shellPID = oldProcess.shellProcessID
        let shellPGID = shellPID > 0 ? getpgid(shellPID) : -1
        let foregroundPGID: pid_t
        if oldProcess.childFileDescriptor >= 0 {
            foregroundPGID = tcgetpgrp(oldProcess.childFileDescriptor)
        } else {
            foregroundPGID = -1
        }
        process = nil
        processBridge = nil
        _ = generationGate.acceptTermination(from: generation)
        releaseRunningPTYCount()
        return (
            oldProcess,
            ProcessIdentity(
                processID: shellPID,
                shellProcessGroupID: shellPGID > 0 ? shellPGID : nil,
                foregroundProcessGroupID: foregroundPGID > 0 ? foregroundPGID : nil
            )
        )
    }

    private func releaseRunningPTYCount() {
        guard countsRunningPTY else { return }
        countsRunningPTY = false
        PaneResourceCounters.decrement(.runningPTY)
    }

    nonisolated private static func signalProcessGroups(
        _ identity: ProcessIdentity,
        signal: Int32
    ) {
        let applicationProcessGroup = getpgrp()
        var signaledGroups: Set<pid_t> = []
        for group in [
            identity.foregroundProcessGroupID,
            identity.shellProcessGroupID
        ].compactMap({ $0 }) where group > 0 && group != applicationProcessGroup {
            guard signaledGroups.insert(group).inserted else { continue }
            _ = Darwin.kill(-group, signal)
        }
    }

    nonisolated private static func reapBounded(
        _ identity: ProcessIdentity,
        gracefulWait: Duration,
        killWait: Duration
    ) async -> PTYTerminationResult {
        let started = ContinuousClock.now
        guard identity.processID > 0 else {
            return PTYTerminationResult(
                processID: nil,
                outcome: .terminated,
                elapsed: started.duration(to: .now)
            )
        }

        if await waitForExit(identity.processID, timeout: gracefulWait) {
            return PTYTerminationResult(
                processID: identity.processID,
                outcome: .terminated,
                elapsed: started.duration(to: .now)
            )
        }

        signalProcessGroups(identity, signal: SIGKILL)
        _ = Darwin.kill(identity.processID, SIGKILL)
        let killed = await waitForExit(identity.processID, timeout: killWait)
        return PTYTerminationResult(
            processID: identity.processID,
            outcome: killed ? .killed : .timedOut,
            elapsed: started.duration(to: .now)
        )
    }

    nonisolated private static func waitForExit(
        _ processID: pid_t,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            var status: Int32 = 0
            let result = Darwin.waitpid(processID, &status, WNOHANG)
            if result == processID || (result == -1 && errno == ECHILD) {
                return true
            }
            if result == -1 && errno != EINTR {
                return true
            }
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(20))
        } while !Task.isCancelled
        return false
    }

#if DEBUG
    var debugHasProcessReference: Bool { process != nil || processBridge != nil }

    nonisolated private static func lifecycleLog(_ event: String, id: UUID, detail: String) {
        print("Pane lifecycle PTY[\(id.uuidString)] \(event) \(detail)")
    }
#endif

    nonisolated private static func equalWindowSizes(
        _ lhs: winsize,
        _ rhs: winsize
    ) -> Bool {
        lhs.ws_row == rhs.ws_row
            && lhs.ws_col == rhs.ws_col
            && lhs.ws_xpixel == rhs.ws_xpixel
            && lhs.ws_ypixel == rhs.ws_ypixel
    }
}
