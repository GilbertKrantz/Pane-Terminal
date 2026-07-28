import Darwin
import Foundation
@preconcurrency import SwiftTerm

struct PTYForegroundStatus: Equatable, Sendable {
    let processGroupID: pid_t
    let shellProcessGroupID: pid_t?
    let isRawInput: Bool
    let echoEnabled: Bool
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
    private var generationGate = PTYGenerationGate()
    private let processFactory: ProcessFactory
    private let resizeHandler: ResizeHandler
    private let terminationDelay: DispatchTimeInterval

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

        let running = newProcess.running
        if !running {
            process = nil
            processBridge = nil
            _ = generationGate.acceptTermination(from: nextGeneration)
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
        guard let oldProcess = process else { return }
        process = nil
        processBridge = nil
        _ = generationGate.acceptTermination(from: generation)

        let pid = oldProcess.shellProcessID
        oldProcess.terminate()
        Self.reap(pid)
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
        let isRawInput = hasTermios
            && (localFlags & tcflag_t(ICANON) == 0 || !echoEnabled)
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
        onEvent?(.terminated(waitStatus: waitStatus))
    }

    nonisolated private static func reap(_ pid: pid_t) {
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while Darwin.waitpid(pid, &status, 0) == -1 {
                guard errno == EINTR else { return }
            }
        }
    }

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
