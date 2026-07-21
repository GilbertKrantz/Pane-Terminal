import Foundation

enum InputMode: String, CaseIterable, Equatable, Sendable {
    case blocks
    case terminal

    var title: String {
        switch self {
        case .blocks: "Blocks Mode"
        case .terminal: "Terminal Mode"
        }
    }

    var shortTitle: String {
        switch self {
        case .blocks: "Blocks"
        case .terminal: "Terminal"
        }
    }

    mutating func toggle() {
        self = self == .blocks ? .terminal : .blocks
    }
}
