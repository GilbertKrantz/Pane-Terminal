import Foundation

enum TerminalReplaySanitizer {
    private static let escape: UInt8 = 0x1B
    private static let bell: UInt8 = 0x07
    private static let c1DCS: UInt8 = 0x90
    private static let c1SOS: UInt8 = 0x98
    private static let c1CSI: UInt8 = 0x9B
    private static let c1ST: UInt8 = 0x9C
    private static let c1OSC: UInt8 = 0x9D
    private static let c1PM: UInt8 = 0x9E
    private static let c1APC: UInt8 = 0x9F

    /// Removes terminal sequences that can cause side effects during replay while
    /// preserving visual VT output such as SGR styling, cursor movement, and
    /// OSC 8 hyperlinks.
    nonisolated static func sanitize(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }

        var output = Data()
        output.reserveCapacity(data.count)
        let bytes = Array(data)
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]

            if byte == bell {
                index += 1
                continue
            }

            if byte == escape, index + 1 < bytes.count {
                let next = bytes[index + 1]
                if next == 0x5D { // OSC
                    let sequenceEnd = stringSequenceEnd(
                        in: bytes,
                        startingAt: index + 2,
                        allowsBellTerminator: true
                    )
                    if isHyperlinkOSC(in: bytes, payloadStart: index + 2, sequenceEnd: sequenceEnd) {
                        output.append(contentsOf: bytes[index..<sequenceEnd])
                    }
                    index = sequenceEnd
                    continue
                }
                if next == 0x50 || next == 0x5E || next == 0x5F { // DCS/PM/APC
                    index = stringSequenceEnd(
                        in: bytes,
                        startingAt: index + 2,
                        allowsBellTerminator: false
                    )
                    continue
                }
                if next == 0x5B, let finalIndex = csiFinalIndex(in: bytes, startingAt: index + 2) {
                    let final = bytes[finalIndex]
                    if final == 0x6E || final == 0x63 || final == 0x74 {
                        // DSR, DA, and window-manipulation/query sequences.
                        index = finalIndex + 1
                        continue
                    }
                }
            }

            if byte == c1OSC {
                let sequenceEnd = stringSequenceEnd(
                    in: bytes,
                    startingAt: index + 1,
                    allowsBellTerminator: true
                )
                if isHyperlinkOSC(in: bytes, payloadStart: index + 1, sequenceEnd: sequenceEnd) {
                    output.append(contentsOf: bytes[index..<sequenceEnd])
                }
                index = sequenceEnd
                continue
            }

            if byte == c1DCS || byte == c1SOS || byte == c1PM || byte == c1APC {
                index = stringSequenceEnd(
                    in: bytes,
                    startingAt: index + 1,
                    allowsBellTerminator: false
                )
                continue
            }

            if byte == c1CSI,
               let finalIndex = csiFinalIndex(in: bytes, startingAt: index + 1) {
                let final = bytes[finalIndex]
                if final == 0x6E || final == 0x63 || final == 0x74 {
                    index = finalIndex + 1
                    continue
                }
            }

            if byte == c1ST {
                index += 1
                continue
            }

            output.append(byte)
            index += 1
        }

        return output
    }

    private nonisolated static func stringSequenceEnd(
        in bytes: [UInt8],
        startingAt start: Int,
        allowsBellTerminator: Bool
    ) -> Int {
        var index = start
        while index < bytes.count {
            if allowsBellTerminator, bytes[index] == bell {
                return index + 1
            }
            if bytes[index] == c1ST {
                return index + 1
            }
            if bytes[index] == escape, index + 1 < bytes.count, bytes[index + 1] == 0x5C {
                return index + 2
            }
            index += 1
        }
        return bytes.count
    }

    private nonisolated static func isHyperlinkOSC(
        in bytes: [UInt8],
        payloadStart: Int,
        sequenceEnd: Int
    ) -> Bool {
        guard payloadStart + 1 < sequenceEnd else { return false }
        return bytes[payloadStart] == 0x38 && bytes[payloadStart + 1] == 0x3B
    }

    private nonisolated static func csiFinalIndex(in bytes: [UInt8], startingAt start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if (0x40...0x7E).contains(bytes[index]) { return index }
            index += 1
        }
        return nil
    }
}
