import Darwin
import Foundation

/// A per-shell endpoint created by Pane and bound by the warm interactive zsh.
/// The short `/tmp` path stays below `sockaddr_un.sun_path` on macOS, while the
/// containing directory prevents other users from connecting to the socket.
struct WarmZshCompletionEndpoint: Equatable, Sendable {
    let generation: UInt64
    let socketPath: String

    fileprivate let directoryURL: URL
    fileprivate let identifier: UUID
}

/// Exchanges completion frames with the user's existing interactive zsh.
///
/// A fresh connection is used for each request. Socket work never runs on the
/// main actor, every operation shares one hard deadline, and starting a newer
/// request shuts down the older descriptor so stale completions cannot win.
final class WarmZshCompletionClient: @unchecked Sendable {
    enum EndpointError: Error {
        case shutDown
        case unableToCreatePrivateDirectory
        case socketPathTooLong
    }

    private struct State {
        var isShutDown = false
        var currentEndpointID: UUID?
        var endpointDirectories: [UUID: URL] = [:]
        var nextRequestSequence: UInt64 = 0
        var currentRequestSequence: UInt64?
        var activeSocket: Int32?
    }

    private struct RequestTicket: Sendable {
        let sequence: UInt64
        let requestID: String
    }

    private static let socketDirectoryPrefix = "pane-c-"
    private static let socketFileName = "c"
    private static let maximumDirectoryCreationAttempts = 8

    private let stateLock = NSLock()
    private var state = State()
    private let workQueue = DispatchQueue(
        label: "com.pane.warm-zsh-completion",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let requestTimeout: TimeInterval

    init(requestTimeout: TimeInterval = 0.9) {
        self.requestTimeout = max(0.05, requestTimeout)
    }

    deinit {
        shutdown()
    }

    /// Creates a unique, mode-0700 directory. zsh subsequently creates and
    /// owns the socket node at `socketPath` when shell integration is installed.
    func makeEndpoint(for generation: UInt64) throws -> WarmZshCompletionEndpoint {
        stateLock.lock()
        let isShutDown = state.isShutDown
        stateLock.unlock()
        guard !isShutDown else { throw EndpointError.shutDown }

        let fileManager = FileManager.default
        var endpoint: WarmZshCompletionEndpoint?

        for _ in 0..<Self.maximumDirectoryCreationAttempts {
            let identifier = UUID()
            let suffix = identifier.uuidString
                .replacingOccurrences(of: "-", with: "")
                .prefix(12)
                .lowercased()
            let directoryURL = URL(
                fileURLWithPath: "/tmp/\(Self.socketDirectoryPrefix)\(suffix)",
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                guard Darwin.chmod(directoryURL.path, mode_t(0o700)) == 0 else {
                    try? fileManager.removeItem(at: directoryURL)
                    continue
                }

                let socketPath = directoryURL
                    .appendingPathComponent(Self.socketFileName, isDirectory: false)
                    .path
                guard Self.canRepresentUnixSocketPath(socketPath) else {
                    try? fileManager.removeItem(at: directoryURL)
                    throw EndpointError.socketPathTooLong
                }
                endpoint = WarmZshCompletionEndpoint(
                    generation: generation,
                    socketPath: socketPath,
                    directoryURL: directoryURL,
                    identifier: identifier
                )
                break
            } catch let error as EndpointError {
                throw error
            } catch {
                continue
            }
        }

        guard let endpoint else {
            throw EndpointError.unableToCreatePrivateDirectory
        }

        let oldDirectories: [URL]
        let activeSocket: Int32?
        stateLock.lock()
        if state.isShutDown {
            stateLock.unlock()
            try? fileManager.removeItem(at: endpoint.directoryURL)
            throw EndpointError.shutDown
        }
        oldDirectories = Array(state.endpointDirectories.values)
        activeSocket = state.activeSocket
        if let activeSocket {
            Darwin.shutdown(activeSocket, SHUT_RDWR)
        }
        state.activeSocket = nil
        state.currentRequestSequence = nil
        state.endpointDirectories.removeAll(keepingCapacity: true)
        state.endpointDirectories[endpoint.identifier] = endpoint.directoryURL
        state.currentEndpointID = endpoint.identifier
        stateLock.unlock()
        for directory in oldDirectories where directory != endpoint.directoryURL {
            try? fileManager.removeItem(at: directory)
        }
        return endpoint
    }

    /// Returns a parsed response for a current request. Transport failures,
    /// cancellation, endpoint replacement, and late responses all return nil.
    func completions(
        for buffer: String,
        cursorCharacterOffset: Int,
        endpoint: WarmZshCompletionEndpoint
    ) async -> ZshCompletionProtocol.Response? {
        guard let ticket = beginRequest(for: endpoint) else { return nil }

        let protocolDeadline = Date().addingTimeInterval(requestTimeout)
        guard let request = ZshCompletionProtocol.requestBytes(
            requestID: ticket.requestID,
            buffer: buffer,
            cursorCharacterOffset: cursorCharacterOffset,
            deadline: protocolDeadline
        ) else {
            finishRequest(ticket)
            return nil
        }

        let monotonicDeadline = Self.monotonicDeadline(after: requestTimeout)
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                workQueue.async { [self] in
                    let response = performRequest(
                        request,
                        expectedRequestID: ticket.requestID,
                        endpoint: endpoint,
                        ticket: ticket,
                        deadline: monotonicDeadline
                    )
                    continuation.resume(returning: response)
                }
            }
        }, onCancel: { [weak self] in
            self?.cancelRequest(ticket)
        })
    }

    /// Convenience for AppKit editors, whose selection offsets are UTF-16.
    func completions(
        for buffer: String,
        cursorUTF16Offset: Int,
        endpoint: WarmZshCompletionEndpoint
    ) async -> ZshCompletionProtocol.Response? {
        await completions(
            for: buffer,
            cursorCharacterOffset: Self.zshCharacterOffset(
                in: buffer,
                utf16Offset: cursorUTF16Offset
            ),
            endpoint: endpoint
        )
    }

    /// Invalidates requests and removes the private endpoint directory. The
    /// shell process should be stopped (or its listener closed) before calling.
    func invalidate(_ endpoint: WarmZshCompletionEndpoint) {
        var directory: URL?
        var activeSocket: Int32?
        stateLock.lock()
        if state.currentEndpointID == endpoint.identifier {
            state.currentEndpointID = nil
            state.currentRequestSequence = nil
            activeSocket = state.activeSocket
            state.activeSocket = nil
        }
        directory = state.endpointDirectories.removeValue(forKey: endpoint.identifier)
        if let activeSocket {
            Darwin.shutdown(activeSocket, SHUT_RDWR)
        }
        stateLock.unlock()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func shutdown() {
        let directories: [URL]
        let activeSocket: Int32?
        stateLock.lock()
        guard !state.isShutDown else {
            stateLock.unlock()
            return
        }
        state.isShutDown = true
        state.currentEndpointID = nil
        state.currentRequestSequence = nil
        activeSocket = state.activeSocket
        state.activeSocket = nil
        directories = Array(state.endpointDirectories.values)
        state.endpointDirectories.removeAll(keepingCapacity: false)
        if let activeSocket {
            Darwin.shutdown(activeSocket, SHUT_RDWR)
        }
        stateLock.unlock()
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func beginRequest(
        for endpoint: WarmZshCompletionEndpoint
    ) -> RequestTicket? {
        let previousSocket: Int32?
        let ticket: RequestTicket
        stateLock.lock()
        guard !state.isShutDown,
              state.currentEndpointID == endpoint.identifier,
              state.endpointDirectories[endpoint.identifier] == endpoint.directoryURL else {
            stateLock.unlock()
            return nil
        }
        state.nextRequestSequence &+= 1
        let sequence = state.nextRequestSequence
        ticket = RequestTicket(
            sequence: sequence,
            requestID: "g\(endpoint.generation)-r\(sequence)"
        )
        previousSocket = state.activeSocket
        if let previousSocket {
            Darwin.shutdown(previousSocket, SHUT_RDWR)
        }
        state.activeSocket = nil
        state.currentRequestSequence = sequence
        stateLock.unlock()
        return ticket
    }

    private func cancelRequest(_ ticket: RequestTicket) {
        stateLock.lock()
        if state.currentRequestSequence == ticket.sequence {
            state.currentRequestSequence = nil
            if let activeSocket = state.activeSocket {
                Darwin.shutdown(activeSocket, SHUT_RDWR)
            }
            state.activeSocket = nil
        }
        stateLock.unlock()
    }

    private func finishRequest(_ ticket: RequestTicket) {
        stateLock.lock()
        if state.currentRequestSequence == ticket.sequence {
            state.currentRequestSequence = nil
            state.activeSocket = nil
        }
        stateLock.unlock()
    }

    private func register(
        socket: Int32,
        ticket: RequestTicket,
        endpoint: WarmZshCompletionEndpoint
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !state.isShutDown,
              state.currentEndpointID == endpoint.identifier,
              state.currentRequestSequence == ticket.sequence else {
            return false
        }
        state.activeSocket = socket
        return true
    }

    private func isCurrent(
        _ ticket: RequestTicket,
        endpoint: WarmZshCompletionEndpoint
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !state.isShutDown
            && state.currentEndpointID == endpoint.identifier
            && state.currentRequestSequence == ticket.sequence
    }

    private func performRequest(
        _ request: Data,
        expectedRequestID: String,
        endpoint: WarmZshCompletionEndpoint,
        ticket: RequestTicket,
        deadline: UInt64
    ) -> ZshCompletionProtocol.Response? {
        guard request.count <= ZshCompletionProtocol.maximumRequestBodyBytes
                + ZshCompletionProtocol.headerByteCount else {
            Self.debug("request exceeds protocol cap")
            finishRequest(ticket)
            return nil
        }
        guard isCurrent(ticket, endpoint: endpoint) else {
            Self.debug("request is stale before socket creation")
            finishRequest(ticket)
            return nil
        }
        guard let socket = Self.makeSocket() else {
            Self.debug("socket creation failed errno=\(errno)")
            finishRequest(ticket)
            return nil
        }
        defer {
            close(socket: socket, ticket: ticket)
        }

        guard register(socket: socket, ticket: ticket, endpoint: endpoint) else {
            Self.debug("request became stale before connect")
            return nil
        }
        guard Self.connect(socket, to: endpoint.socketPath, deadline: deadline) else {
            Self.debug("connect failed errno=\(errno)")
            return nil
        }
        guard isCurrent(ticket, endpoint: endpoint) else {
            Self.debug("request became stale after connect")
            return nil
        }
        guard Self.writeAll(request, to: socket, deadline: deadline) else {
            Self.debug("request write failed errno=\(errno)")
            return nil
        }
        guard let header = Self.readExactly(
            ZshCompletionProtocol.headerByteCount,
            from: socket,
            deadline: deadline
        ) else {
            Self.debug("response header read failed errno=\(errno)")
            return nil
        }
        guard let bodyLength = ZshCompletionProtocol.bodyLength(
            fromHeader: header,
            maximum: ZshCompletionProtocol.maximumResponseBodyBytes
        ) else {
            Self.debug("invalid response header \(String(decoding: header, as: UTF8.self))")
            return nil
        }
        guard let body = Self.readExactly(bodyLength, from: socket, deadline: deadline) else {
            Self.debug("response body read failed errno=\(errno)")
            return nil
        }
        guard let response = ZshCompletionProtocol.parseResponseBody(body) else {
            Self.debug("response body failed protocol parsing")
            return nil
        }
        let responseIsCurrent = isCurrent(ticket, endpoint: endpoint)
        guard response.requestID == expectedRequestID, responseIsCurrent else {
            Self.debug(
                "response mismatch expected=\(expectedRequestID) actual=\(response.requestID) "
                    + "status=\(response.status.rawValue) current=\(responseIsCurrent)"
            )
            return nil
        }
        return response
    }

    private func close(socket: Int32, ticket: RequestTicket) {
        // Serialize descriptor teardown with replacement/cancellation. Without
        // this lock, a closed descriptor number could be reused by a newer
        // request just before an older request calls shutdown on that number.
        stateLock.lock()
        if state.activeSocket == socket {
            state.activeSocket = nil
        }
        if state.currentRequestSequence == ticket.sequence {
            state.currentRequestSequence = nil
        }
        Darwin.close(socket)
        stateLock.unlock()
    }
}

private extension WarmZshCompletionClient {
    static func debug(_ message: @autoclosure () -> String) {
#if DEBUG
        guard ProcessInfo.processInfo.environment["PANE_COMPLETION_DEBUG"] != nil else {
            return
        }
        print("Pane completion transport: \(message())")
#endif
    }

    static func canRepresentUnixSocketPath(_ path: String) -> Bool {
        var address = sockaddr_un()
        let capacity = withUnsafeBytes(of: &address.sun_path) { $0.count }
        return !path.utf8.contains(0) && path.utf8.count < capacity
    }

    static func makeSocket() -> Int32? {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
            Darwin.close(descriptor)
            return nil
        }
        let currentFlags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard currentFlags != -1,
              Darwin.fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) != -1 else {
            Darwin.close(descriptor)
            return nil
        }
        var noSignal: Int32 = 1
        guard Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    static func connect(_ descriptor: Int32, to path: String, deadline: UInt64) -> Bool {
        guard canRepresentUnixSocketPath(path) else { return false }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS || errno == EWOULDBLOCK,
              wait(for: Int16(POLLOUT), on: descriptor, deadline: deadline) else {
            return false
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout.size(ofValue: socketError))
        return Darwin.getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        ) == 0 && socketError == 0
    }

    static func writeAll(_ data: Data, to descriptor: Int32, deadline: UInt64) -> Bool {
        var offset = 0
        while offset < data.count {
            guard wait(for: Int16(POLLOUT), on: descriptor, deadline: deadline) else {
                return false
            }
            let count = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count == -1 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            } else {
                return false
            }
        }
        return true
    }

    static func readExactly(
        _ count: Int,
        from descriptor: Int32,
        deadline: UInt64
    ) -> Data? {
        guard count > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        var bytes = [UInt8](repeating: 0, count: min(count, 16_384))

        while result.count < count {
            guard wait(for: Int16(POLLIN), on: descriptor, deadline: deadline) else {
                return nil
            }
            let requested = min(bytes.count, count - result.count)
            let readCount = Darwin.read(descriptor, &bytes, requested)
            if readCount > 0 {
                result.append(contentsOf: bytes.prefix(readCount))
            } else if readCount == -1
                        && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            } else {
                return nil
            }
        }
        return result
    }

    static func wait(for events: Int16, on descriptor: Int32, deadline: UInt64) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remainingNanoseconds = deadline - now
            let remainingMilliseconds = min(
                (remainingNanoseconds + 999_999) / 1_000_000,
                UInt64(Int32.max)
            )
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(max(1, remainingMilliseconds)))
            if result > 0 {
                if item.revents & events != 0 { return true }
                if item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    return false
                }
                continue
            }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    static func monotonicDeadline(after interval: TimeInterval) -> UInt64 {
        let nanoseconds = UInt64(min(interval * 1_000_000_000, Double(UInt64.max)))
        return DispatchTime.now().uptimeNanoseconds &+ nanoseconds
    }


    static func zshCharacterOffset(in text: String, utf16Offset: Int) -> Int {
        let clampedOffset = min(max(0, utf16Offset), text.utf16.count)
        let utf16Index = text.utf16.index(
            text.utf16.startIndex,
            offsetBy: clampedOffset
        )
        guard let stringIndex = String.Index(utf16Index, within: text) else {
            return text.unicodeScalars.count
        }
        return text[..<stringIndex].unicodeScalars.count
    }
}
