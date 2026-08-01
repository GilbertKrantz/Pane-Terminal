import Foundation

/// Machine-readable result emitted by compatibility runners.
struct TerminalCompatibilityResult: Codable, Equatable, Sendable {
    let fixtureID: String
    let applicationName: String
    let passed: Bool
    let duration: Duration
    let failureCategory: CompatibilityFailureCategory?
    let diagnostic: String?

    enum CodingKeys: String, CodingKey {
        case fixtureID
        case applicationName
        case passed
        case durationSeconds
        case failureCategory
        case diagnostic
    }

    init(
        fixtureID: String,
        applicationName: String,
        passed: Bool,
        duration: Duration,
        failureCategory: CompatibilityFailureCategory? = nil,
        diagnostic: String? = nil
    ) {
        self.fixtureID = fixtureID
        self.applicationName = applicationName
        self.passed = passed
        self.duration = duration
        self.failureCategory = failureCategory
        self.diagnostic = diagnostic
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fixtureID = try values.decode(String.self, forKey: .fixtureID)
        applicationName = try values.decode(String.self, forKey: .applicationName)
        passed = try values.decode(Bool.self, forKey: .passed)
        duration = .seconds(
            try values.decode(Double.self, forKey: .durationSeconds)
        )
        failureCategory = try values.decodeIfPresent(
            CompatibilityFailureCategory.self,
            forKey: .failureCategory
        )
        diagnostic = try values.decodeIfPresent(
            String.self,
            forKey: .diagnostic
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(fixtureID, forKey: .fixtureID)
        try values.encode(applicationName, forKey: .applicationName)
        try values.encode(passed, forKey: .passed)
        try values.encode(duration.seconds, forKey: .durationSeconds)
        try values.encodeIfPresent(failureCategory, forKey: .failureCategory)
        try values.encodeIfPresent(diagnostic, forKey: .diagnostic)
    }
}

enum CompatibilityFailureCategory: String, Codable, Sendable {
    case launch
    case rendering
    case keyboardInput
    case mouseInput
    case focusRestoration
    case alternateScreen
    case resize
    case clipboard
    case processExit
    case cleanup
    case timeout
}

struct WorkspaceStressConfiguration: Codable, Equatable, Sendable {
    let tabCount: Int
    let commandsPerTab: Int
    let switchCount: Int
    let closeCount: Int
    let duration: Duration

    static let baseline = WorkspaceStressConfiguration(
        tabCount: 12,
        commandsPerTab: 20,
        switchCount: 500,
        closeCount: 6,
        duration: .seconds(300)
    )
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
