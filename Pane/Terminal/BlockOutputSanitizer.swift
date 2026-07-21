import Foundation

enum BlockOutputSanitizer {
    static func sanitize(_ data: Data) -> String {
        var result: [UInt8] = []
        result.reserveCapacity(data.count)

        enum State {
            case text
            case escape
            case controlSequence
            case operatingSystemCommand
            case operatingSystemCommandEscape
        }

        var state = State.text
        var controlSequenceParameters: [UInt8] = []

        for byte in data {
            switch state {
            case .text:
                switch byte {
                case 0x1B:
                    state = .escape
                case 0x08, 0x09, 0x0A, 0x0D, 0x20...0xFF:
                    result.append(byte)
                default:
                    break
                }

            case .escape:
                if byte == 0x5B {
                    controlSequenceParameters.removeAll(keepingCapacity: true)
                    state = .controlSequence
                } else if byte == 0x5D {
                    state = .operatingSystemCommand
                } else {
                    state = .text
                }

            case .controlSequence:
                if (0x40...0x7E).contains(byte) {
                    if byte == 0x4B {
                        // Preserve enough erase-line behavior for common
                        // progress renderers. Vertical/form feed are stripped
                        // from normal text and are safe internal sentinels.
                        let clearsWholeLine = controlSequenceParameters == [0x32]
                        result.append(clearsWholeLine ? 0x0B : 0x0C)
                    }
                    state = .text
                } else {
                    controlSequenceParameters.append(byte)
                }

            case .operatingSystemCommand:
                if byte == 0x07 {
                    state = .text
                } else if byte == 0x1B {
                    state = .operatingSystemCommandEscape
                }

            case .operatingSystemCommandEscape:
                state = byte == 0x5C ? .text : .operatingSystemCommand
            }
        }

        return renderTerminalLineOverwrites(String(decoding: result, as: UTF8.self))
            .trimmingCharacters(in: .newlines)
    }

    private static func renderTerminalLineOverwrites(_ text: String) -> String {
        var lines: [[Unicode.Scalar]] = []
        var line: [Unicode.Scalar] = []
        var cursor = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D:
                cursor = 0

            case 0x0A:
                lines.append(line)
                line.removeAll(keepingCapacity: true)
                cursor = 0

            case 0x08:
                cursor = max(0, cursor - 1)

            case 0x0B:
                // CSI 2 K clears the line without moving the cursor.
                line = Array(repeating: Unicode.Scalar(0x20)!, count: cursor)

            case 0x0C:
                // CSI K/0 K clears from the cursor to the end of the line.
                if cursor < line.count {
                    line.removeSubrange(cursor...)
                }

            default:
                if cursor < line.count {
                    line[cursor] = scalar
                } else {
                    if cursor > line.count {
                        line.append(
                            contentsOf: repeatElement(
                                Unicode.Scalar(0x20)!,
                                count: cursor - line.count
                            )
                        )
                    }
                    line.append(scalar)
                }
                cursor += 1
            }
        }

        lines.append(line)
        return lines
            .map { scalars in
                var result = ""
                result.unicodeScalars.append(contentsOf: scalars)
                return result
            }
            .joined(separator: "\n")
    }
}
