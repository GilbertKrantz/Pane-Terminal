import Foundation

/// Removes alternate-screen frames from the command-block transcript while
/// leaving the byte stream sent to the terminal emulator untouched.
struct AlternateScreenTranscriptFilter: Sendable {
    static let transitionPlaceholder = Data("\r\n[Alternate screen active]\r\n".utf8)
    static let maximumPendingSequenceBytes = 64 * 1_024

    private static let escape: UInt8 = 0x1B
    private static let controlSequenceIntroducer: UInt8 = 0x5B
    private static let operatingSystemCommandIntroducer: UInt8 = 0x5D
    private static let stringTerminators: Set<UInt8> = [0x50, 0x58, 0x5E, 0x5F]
    private static let stringTerminator: UInt8 = 0x5C
    private static let bell: UInt8 = 0x07
    private static let lifecycleMarkerPrefix = Array("777;".utf8)
    private static let alternateScreenModes: Set<Int> = [47, 1047, 1049]

    private var pendingBytes: [UInt8] = []
    private(set) var isAlternateScreenActive = false

    mutating func consume(_ data: Data) -> Data {
        pendingBytes.append(contentsOf: data)

        var output: [UInt8] = []
        var cursor = 0

        parseLoop: while cursor < pendingBytes.count {
            guard pendingBytes[cursor] == Self.escape else {
                let nextEscape = pendingBytes[cursor...]
                    .firstIndex(of: Self.escape) ?? pendingBytes.endIndex
                appendIfVisible(pendingBytes[cursor..<nextEscape], to: &output)
                cursor = nextEscape
                continue
            }

            guard cursor + 1 < pendingBytes.count else { break }
            let introducer = pendingBytes[cursor + 1]

            switch introducer {
            case Self.controlSequenceIntroducer:
                switch controlSequenceEnd(startingAt: cursor + 2) {
                case .incomplete:
                    break parseLoop
                case .malformed:
                    appendIfVisible(pendingBytes[cursor..<(cursor + 2)], to: &output)
                    cursor += 2
                case .complete(let endIndex):
                    let sequence = pendingBytes[cursor...endIndex]
                    if let shouldActivate = alternateScreenTransition(in: sequence) {
                        if shouldActivate, !isAlternateScreenActive {
                            output.append(contentsOf: Self.transitionPlaceholder)
                        }
                        isAlternateScreenActive = shouldActivate
                    } else {
                        appendIfVisible(sequence, to: &output)
                    }
                    cursor = endIndex + 1
                }

            case Self.operatingSystemCommandIntroducer:
                guard let endIndex = stringSequenceEnd(
                    startingAt: cursor + 2,
                    allowsBellTerminator: true
                ) else {
                    break parseLoop
                }

                let sequence = pendingBytes[cursor...endIndex]
                if !isAlternateScreenActive || isLifecycleMarker(sequence) {
                    output.append(contentsOf: sequence)
                }
                cursor = endIndex + 1

            case let value where Self.stringTerminators.contains(value):
                guard let endIndex = stringSequenceEnd(
                    startingAt: cursor + 2,
                    allowsBellTerminator: false
                ) else {
                    break parseLoop
                }
                appendIfVisible(pendingBytes[cursor...endIndex], to: &output)
                cursor = endIndex + 1

            case Self.escape:
                // Let the second escape begin a fresh sequence instead of
                // consuming it as the final byte of this malformed sequence.
                appendIfVisible(pendingBytes[cursor...cursor], to: &output)
                cursor += 1

            default:
                appendIfVisible(pendingBytes[cursor..<(cursor + 2)], to: &output)
                cursor += 2
            }
        }

        if cursor > 0 {
            pendingBytes.removeFirst(cursor)
        }
        discardOversizedPendingSequenceIfNeeded()
        return Data(output)
    }

    /// Returns any unterminated bytes that can safely belong to the normal
    /// transcript. Unterminated alternate-screen data remains suppressed.
    mutating func flush() -> Data {
        defer { pendingBytes.removeAll(keepingCapacity: false) }
        guard !isAlternateScreenActive else { return Data() }
        return Data(pendingBytes)
    }

    private mutating func appendIfVisible<C: Collection>(
        _ bytes: C,
        to output: inout [UInt8]
    ) where C.Element == UInt8 {
        guard !isAlternateScreenActive else { return }
        output.append(contentsOf: bytes)
    }

    /// An unterminated OSC/DCS/PM/APC or CSI must not retain arbitrary command
    /// output forever. Once the sequence exceeds the safety limit, discard it
    /// and resume parsing from a clean boundary on the next PTY chunk. The
    /// active-buffer flag is intentionally preserved because this malformed
    /// control string is independent of DEC alternate-screen state.
    private mutating func discardOversizedPendingSequenceIfNeeded() {
        guard pendingBytes.count > Self.maximumPendingSequenceBytes else { return }
        pendingBytes.removeAll(keepingCapacity: false)
    }

    private enum ControlSequenceEnd {
        case incomplete
        case malformed
        case complete(Int)
    }

    private func controlSequenceEnd(startingAt startIndex: Int) -> ControlSequenceEnd {
        var index = startIndex
        while index < pendingBytes.count {
            let byte = pendingBytes[index]
            if (0x40...0x7E).contains(byte) {
                return .complete(index)
            }
            guard (0x20...0x3F).contains(byte) else {
                return .malformed
            }
            index += 1
        }
        return .incomplete
    }

    private func stringSequenceEnd(
        startingAt startIndex: Int,
        allowsBellTerminator: Bool
    ) -> Int? {
        var index = startIndex
        while index < pendingBytes.count {
            if allowsBellTerminator, pendingBytes[index] == Self.bell {
                return index
            }
            if pendingBytes[index] == Self.escape,
               index + 1 < pendingBytes.count,
               pendingBytes[index + 1] == Self.stringTerminator {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private func alternateScreenTransition<C: Collection>(in sequence: C) -> Bool?
    where C.Element == UInt8 {
        let bytes = Array(sequence)
        guard bytes.count >= 5,
              bytes[0] == Self.escape,
              bytes[1] == Self.controlSequenceIntroducer,
              bytes[2] == 0x3F,
              let finalByte = bytes.last,
              finalByte == 0x68 || finalByte == 0x6C else {
            return nil
        }

        let parameterBytes = bytes.dropFirst(3).dropLast()
        let parameters = String(decoding: parameterBytes, as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: true)
            .compactMap { Int($0) }
        guard parameters.contains(where: Self.alternateScreenModes.contains) else {
            return nil
        }
        return finalByte == 0x68
    }

    private func isLifecycleMarker<C: Collection>(_ sequence: C) -> Bool
    where C.Element == UInt8 {
        let bytes = Array(sequence)
        let payloadStart = 2
        guard bytes.count >= payloadStart + Self.lifecycleMarkerPrefix.count else {
            return false
        }
        return bytes[payloadStart..<(payloadStart + Self.lifecycleMarkerPrefix.count)]
            .elementsEqual(Self.lifecycleMarkerPrefix)
    }
}
