import Foundation

struct CompactedBlockOutput: Equatable, Sendable {
    let text: String
    let kind: PersistedOutputKind
    let omittedByteCount: Int
}

/// A single bounded capture shared by the plain-text block output and terminal
/// replay paths. It preserves the beginning and end of a command without
/// retaining the potentially unbounded bytes between them.
struct BoundedHeadTailByteCapture: Sendable {
    private let headLimit: Int
    private let tailLimit: Int
    private var head = Data()
    private var tail = BoundedByteTail(limit: 0)
    private(set) var totalByteCount = 0

    init(limit: Int) {
        let boundedLimit = max(0, limit)
        headLimit = boundedLimit / 2
        tailLimit = boundedLimit - headLimit
        tail = BoundedByteTail(limit: tailLimit)
    }

    var isEmpty: Bool {
        totalByteCount == 0
    }

    var isTruncated: Bool {
        totalByteCount > retainedByteCount
    }

    var omittedByteCount: Int {
        max(0, totalByteCount - retainedByteCount)
    }

    var retainedByteCount: Int {
        head.count + tail.data.count
    }

    var headData: Data {
        head
    }

    var tailData: Data {
        tail.data
    }

    var data: Data {
        var result = Data()
        result.reserveCapacity(retainedByteCount)
        result.append(head)
        result.append(tail.data)
        return result
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        totalByteCount += data.count

        let remainingHeadCapacity = max(0, headLimit - head.count)
        if remainingHeadCapacity > 0 {
            let prefixCount = min(remainingHeadCapacity, data.count)
            head.append(data.prefix(prefixCount))
            if prefixCount < data.count {
                tail.append(Data(data.dropFirst(prefixCount)))
            }
        } else {
            tail.append(data)
        }
    }

    mutating func removeAll() {
        head.removeAll(keepingCapacity: false)
        tail.removeAll()
        totalByteCount = 0
    }
}

enum BoundedOutputCompactor {
    static let headByteLimit = 128 * 1_024

    nonisolated static func compact(
        _ text: String,
        byteLimit: Int
    ) -> CompactedBlockOutput {
        let boundedLimit = max(0, byteLimit)
        let totalBytes = text.utf8.count
        guard totalBytes > boundedLimit else {
            return CompactedBlockOutput(
                text: text,
                kind: text.isEmpty ? .none : .complete,
                omittedByteCount: 0
            )
        }

        guard boundedLimit > 0 else {
            return CompactedBlockOutput(
                text: "",
                kind: .excerpt,
                omittedByteCount: totalBytes
            )
        }

        var omittedBytes = max(1, totalBytes - boundedLimit)
        var marker = omissionMarker(omittedByteCount: omittedBytes)
        var head = Data()
        var tail = Data()

        // The byte count is included in the marker, so converge after the
        // marker's decimal width and the UTF-8 suffix boundary are known.
        for _ in 0..<4 {
            let headBudget = min(
                headByteLimit,
                max(0, boundedLimit - marker.count)
            )
            head = utf8SafePrefix(text, byteLimit: headBudget)
            let tailBudget = max(0, boundedLimit - head.count - marker.count)
            tail = utf8SafeSuffix(text, byteLimit: tailBudget)
            omittedBytes = max(0, totalBytes - head.count - tail.count)
            let updatedMarker = omissionMarker(omittedByteCount: omittedBytes)
            if updatedMarker.count == marker.count {
                marker = updatedMarker
                break
            }
            marker = updatedMarker
        }

        let headBudget = min(
            headByteLimit,
            max(0, boundedLimit - marker.count)
        )
        head = utf8SafePrefix(text, byteLimit: headBudget)
        let tailBudget = max(0, boundedLimit - head.count - marker.count)
        tail = utf8SafeSuffix(text, byteLimit: tailBudget)
        omittedBytes = max(0, totalBytes - head.count - tail.count)
        marker = omissionMarker(omittedByteCount: omittedBytes)

        // A decimal-width transition can make the last marker one byte wider.
        // Recompute both grapheme-safe slices and always preserve the marker.
        if head.count + marker.count + tail.count > boundedLimit {
            let correctedHeadBudget = min(
                headByteLimit,
                max(0, boundedLimit - marker.count)
            )
            head = utf8SafePrefix(text, byteLimit: correctedHeadBudget)
            let correctedTailBudget = max(
                0,
                boundedLimit - head.count - marker.count
            )
            tail = utf8SafeSuffix(text, byteLimit: correctedTailBudget)
            omittedBytes = max(0, totalBytes - head.count - tail.count)
            marker = omissionMarker(omittedByteCount: omittedBytes)
        }

        if marker.count > boundedLimit {
            let markerText = String(decoding: marker, as: UTF8.self)
            let boundedMarker = utf8SafePrefix(markerText, byteLimit: boundedLimit)
            return CompactedBlockOutput(
                text: String(decoding: boundedMarker, as: UTF8.self),
                kind: .excerpt,
                omittedByteCount: totalBytes
            )
        }

        var output = Data()
        output.reserveCapacity(head.count + marker.count + tail.count)
        output.append(head)
        output.append(marker)
        output.append(tail)

        return CompactedBlockOutput(
            text: String(decoding: output, as: UTF8.self),
            kind: .excerpt,
            omittedByteCount: omittedBytes
        )
    }

    nonisolated static func compactSanitizedCapture(
        _ capture: BoundedHeadTailByteCapture,
        byteLimit: Int
    ) -> CompactedBlockOutput {
        guard !capture.isEmpty else {
            return CompactedBlockOutput(text: "", kind: .none, omittedByteCount: 0)
        }

        var head = BlockOutputSanitizer.sanitize(
            utf8BoundarySafeHead(capture.headData)
        )
        var tail = BlockOutputSanitizer.sanitize(
            utf8BoundarySafeTail(capture.tailData)
        )
        guard capture.isTruncated else {
            return compact(head + tail, byteLimit: byteLimit)
        }

        // A streaming byte cap cannot know whether the omitted neighbor
        // extends the boundary grapheme (combining marks and ZWJ sequences).
        // Dropping the two boundary Characters keeps every presented grapheme
        // complete while preserving essentially the full head/tail budgets.
        if !head.isEmpty {
            head.removeLast()
        }
        if !tail.isEmpty {
            tail.removeFirst()
        }

        let boundedLimit = max(0, byteLimit)
        let originalHeadByteCount = head.utf8.count
        let originalTailByteCount = tail.utf8.count
        var omittedBytes = capture.omittedByteCount
        var marker = omissionMarker(omittedByteCount: omittedBytes)
        var retainedHead = Data()
        var retainedTail = Data()

        for _ in 0..<4 {
            let headBudget = min(
                headByteLimit,
                max(0, boundedLimit - marker.count)
            )
            retainedHead = utf8SafePrefix(head, byteLimit: headBudget)
            let tailBudget = max(
                0,
                boundedLimit - retainedHead.count - marker.count
            )
            retainedTail = utf8SafeSuffix(tail, byteLimit: tailBudget)
            omittedBytes = capture.omittedByteCount
                + max(0, originalHeadByteCount - retainedHead.count)
                + max(0, originalTailByteCount - retainedTail.count)
            let updatedMarker = omissionMarker(omittedByteCount: omittedBytes)
            if updatedMarker.count == marker.count {
                marker = updatedMarker
                break
            }
            marker = updatedMarker
        }

        if marker.count > boundedLimit {
            let markerText = String(decoding: marker, as: UTF8.self)
            retainedHead = utf8SafePrefix(markerText, byteLimit: boundedLimit)
            retainedTail = Data()
            marker = Data()
        }

        var output = Data()
        output.reserveCapacity(
            retainedHead.count + marker.count + retainedTail.count
        )
        output.append(retainedHead)
        output.append(marker)
        output.append(retainedTail)
        return CompactedBlockOutput(
            text: String(decoding: output, as: UTF8.self),
            kind: .excerpt,
            omittedByteCount: omittedBytes
        )
    }

    nonisolated static func compactReplay(
        _ capture: BoundedHeadTailByteCapture,
        byteLimit: Int
    ) -> Data {
        guard !capture.isEmpty else { return Data() }

        var safeBytes = Data()
        let safeHead = TerminalReplaySanitizer.sanitize(
            utf8BoundarySafeHead(capture.headData)
        )
        let safeTail = TerminalReplaySanitizer.sanitize(
            utf8BoundarySafeTail(capture.tailData)
        )
        let marker = capture.isTruncated
            ? omissionMarker(omittedByteCount: capture.omittedByteCount)
            : Data()
        let boundedLimit = max(0, byteLimit)
        let headBudget = min(
            headByteLimit,
            max(0, boundedLimit - marker.count)
        )
        let retainedHead = safeHead.prefix(headBudget)
        let tailBudget = max(
            0,
            boundedLimit - retainedHead.count - marker.count
        )
        let retainedTail = safeTail.suffix(tailBudget)

        safeBytes.reserveCapacity(
            retainedHead.count + marker.count + retainedTail.count
        )
        safeBytes.append(retainedHead)
        safeBytes.append(marker.prefix(max(0, boundedLimit - safeBytes.count)))
        safeBytes.append(
            retainedTail.prefix(max(0, boundedLimit - safeBytes.count))
        )
        return safeBytes
    }

    private nonisolated static func omissionMarker(omittedByteCount: Int) -> Data {
        Data("\n… [Pane omitted \(max(0, omittedByteCount)) bytes] …\n".utf8)
    }

    private nonisolated static func utf8SafePrefix(
        _ text: String,
        byteLimit: Int
    ) -> Data {
        guard byteLimit > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(byteLimit)
        for character in text {
            let bytes = Data(String(character).utf8)
            guard result.count + bytes.count <= byteLimit else { break }
            result.append(bytes)
        }
        return result
    }

    private nonisolated static func utf8SafeSuffix(
        _ text: String,
        byteLimit: Int
    ) -> Data {
        guard byteLimit > 0 else { return Data() }
        var reversedCharacters: [Character] = []
        var retainedBytes = 0
        for character in text.reversed() {
            let byteCount = String(character).utf8.count
            guard retainedBytes + byteCount <= byteLimit else { break }
            reversedCharacters.append(character)
            retainedBytes += byteCount
        }
        return Data(String(reversedCharacters.reversed()).utf8)
    }

    private nonisolated static func utf8BoundarySafeHead(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let bytes = [UInt8](data)
        var scalarStart = bytes.count - 1
        while scalarStart > 0, isContinuationByte(bytes[scalarStart]) {
            scalarStart -= 1
        }
        let available = bytes.count - scalarStart
        let expected = utf8ScalarLength(firstByte: bytes[scalarStart])
        guard expected > available else { return data }
        return Data(bytes[..<scalarStart])
    }

    private nonisolated static func utf8BoundarySafeTail(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let bytes = [UInt8](data)
        var firstScalar = 0
        while firstScalar < bytes.count, isContinuationByte(bytes[firstScalar]) {
            firstScalar += 1
        }
        return Data(bytes.dropFirst(firstScalar))
    }

    private nonisolated static func isContinuationByte(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }

    private nonisolated static func utf8ScalarLength(firstByte: UInt8) -> Int {
        switch firstByte {
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return 1
        }
    }
}

/// The actor boundary lets callers finalize very large rendered strings away
/// from the main actor. The synchronous lifecycle path also uses the same
/// deterministic compactor after capture has already bounded the workload.
actor BlockOutputProcessingQueue {
    func compact(_ text: String, policy: ScrollbackPolicy) -> CompactedBlockOutput {
        BoundedOutputCompactor.compact(text, byteLimit: policy.excerptByteLimit)
    }
}
