import Foundation

struct BlockStreamParser: Sendable {
    enum Event: Equatable, Sendable {
        case output(Data)
        case commandStarted
        case commandFinished(exitCode: Int32, workingDirectory: String)
    }

    private static let markerPrefix = Data("\u{001B}]777;Pane;".utf8)
    private static let terminator: UInt8 = 0x07
    static let maximumBufferedMarkerBytes = 64 * 1_024
    private var buffer = Data()

    mutating func consume(_ data: Data) -> [Event] {
        buffer.append(data)
        var events: [Event] = []

        while true {
            guard let markerRange = buffer.range(of: Self.markerPrefix) else {
                let retainedCount = markerPrefixSuffixLength(in: buffer)
                let outputCount = buffer.count - retainedCount
                if outputCount > 0 {
                    events.append(.output(buffer.prefix(outputCount)))
                    buffer.removeFirst(outputCount)
                }
                break
            }

            if markerRange.lowerBound > buffer.startIndex {
                events.append(.output(buffer[..<markerRange.lowerBound]))
            }

            let payloadStart = markerRange.upperBound
            guard let terminatorIndex = buffer[payloadStart...]
                .firstIndex(of: Self.terminator) else {
                buffer.removeSubrange(buffer.startIndex..<markerRange.lowerBound)
                discardOversizedPendingMarkerIfNeeded()
                break
            }

            let markerByteCount = buffer.distance(
                from: markerRange.lowerBound,
                to: terminatorIndex
            ) + 1
            if markerByteCount > Self.maximumBufferedMarkerBytes {
                // Treat an implausibly large lifecycle OSC as malformed. Drop
                // it through BEL, then continue so a later valid marker in the
                // same PTY chunk is still recognized.
                let remainderStart = buffer.index(after: terminatorIndex)
                buffer = Data(buffer[remainderStart...])
                continue
            }

            let payloadData = buffer[payloadStart..<terminatorIndex]
            if let event = parse(payloadData) {
                events.append(event)
            }
            buffer.removeSubrange(buffer.startIndex...terminatorIndex)
        }

        return events
    }

    private mutating func discardOversizedPendingMarkerIfNeeded() {
        guard buffer.count > Self.maximumBufferedMarkerBytes else { return }

        // Retain only a suffix that could begin the marker in the next chunk.
        // Everything else belongs to the oversized, unterminated candidate.
        let retainedCount = markerPrefixSuffixLength(in: buffer)
        if retainedCount > 0 {
            buffer = Data(buffer.suffix(retainedCount))
        } else {
            buffer.removeAll(keepingCapacity: false)
        }
    }

    /// Retain only bytes that could actually be the start of a lifecycle
    /// marker. A fixed prefix-sized tail makes short progress updates appear
    /// one PTY chunk late, which is visible in the live terminal surface.
    private func markerPrefixSuffixLength(in data: Data) -> Int {
        let maximumLength = min(data.count, Self.markerPrefix.count - 1)
        guard maximumLength > 0 else { return 0 }

        for length in stride(from: maximumLength, through: 1, by: -1) {
            if data.suffix(length).elementsEqual(Self.markerPrefix.prefix(length)) {
                return length
            }
        }
        return 0
    }

    mutating func flush() -> [Event] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll(keepingCapacity: false) }
        return [.output(buffer)]
    }

    private func parse(_ payload: Data) -> Event? {
        let text = String(decoding: payload, as: UTF8.self)
        if text == "START" {
            return .commandStarted
        }

        let fields = text.split(
            separator: ";",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard fields.count == 3,
              fields[0] == "END",
              let exitCode = Int32(fields[1]) else {
            return nil
        }
        return .commandFinished(
            exitCode: exitCode,
            workingDirectory: String(fields[2])
        )
    }
}
