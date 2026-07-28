import Foundation

/// Process-generation bookkeeping kept separate from the renderer and UI.
/// A controller may accept output/termination only for the authoritative
/// generation, and each generation can terminate exactly once.
struct PTYGenerationGate: Sendable {
    private(set) var activeGeneration: UInt64 = 0
    private var terminatedGeneration: UInt64?

    mutating func beginReplacement() -> UInt64 {
        activeGeneration &+= 1
        terminatedGeneration = nil
        return activeGeneration
    }

    func acceptsOutput(from generation: UInt64) -> Bool {
        generation == activeGeneration && terminatedGeneration != generation
    }

    mutating func acceptTermination(from generation: UInt64) -> Bool {
        guard generation == activeGeneration, terminatedGeneration != generation else { return false }
        terminatedGeneration = generation
        return true
    }
}
