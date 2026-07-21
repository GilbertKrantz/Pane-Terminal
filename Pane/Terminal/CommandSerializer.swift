import Foundation

enum CommandSerializer {
    private static let bracketedPasteStart = "\u{001B}[200~"
    private static let bracketedPasteEnd = "\u{001B}[201~"

    /// Serializes a command for zsh's line editor. Multiline drafts use
    /// bracketed paste so embedded newlines remain one ZLE buffer and produce
    /// one shell lifecycle (one block) when the final carriage return lands.
    static func serializeCommand(_ command: String) -> [UInt8] {
        // CRLF is one extended grapheme cluster in Swift, so Character-based
        // `contains` misses its individual CR/LF scalars. Inspect UTF-8 bytes.
        guard command.utf8.contains(0x0A) || command.utf8.contains(0x0D) else {
            return serializeInputLine(command)
        }

        return Array(
            (bracketedPasteStart + command + bracketedPasteEnd + "\r").utf8
        )
    }

    /// Serializes line-oriented stdin for a command that is already running.
    /// Do not add bracketed-paste markers here: programs such as `read`,
    /// Python, and `cat` may otherwise receive the escape bytes literally.
    static func serializeInputLine(_ input: String) -> [UInt8] {
        Array((input + "\r").utf8)
    }

    // Kept as the small model API used by existing callers/tests. New code
    // should choose command or stdin serialization explicitly.
    static func serialize(_ command: String) -> [UInt8] {
        serializeCommand(command)
    }
}
