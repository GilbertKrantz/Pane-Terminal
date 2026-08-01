import Foundation

struct ScrollbackPolicy: Equatable, Sendable {
    let terminalLineLimit: Int
    let finalizedBlockLimit: Int
    let retainedOutputByteLimit: Int
    let excerptByteLimit: Int

    static let standard = ScrollbackPolicy(
        terminalLineLimit: 10_000, finalizedBlockLimit: 1_000,
        retainedOutputByteLimit: 4 * 1_024 * 1_024, excerptByteLimit: 256 * 1_024
    )
}
