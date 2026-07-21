import Foundation

enum SensitiveDataCategory: String, Codable, Sendable, Hashable {
    case password
    case apiKey
    case accessToken
    case refreshToken
    case authorizationHeader
    case privateKey
    case databaseCredential
    case cloudCredential
    case sessionCookie
    case connectionString
    case environmentValue
    case unknownSecret
}

struct SanitizedValue: Sendable, Equatable {
    let value: String
    let redactionCount: Int
    let categories: Set<SensitiveDataCategory>
}

protocol SensitiveDataSanitizing: Sendable {
    func sanitizeCommand(_ command: String) -> SanitizedValue
    func sanitizeOutput(_ output: String) -> SanitizedValue
    func sanitizeError(_ error: String) -> SanitizedValue
    func sanitizeEnvironment(_ environment: [String: String]) -> [String: String]
    func containsSensitiveData(_ text: String) -> Bool
}

struct SensitiveDataSanitizer: SensitiveDataSanitizing {
    static let redaction = "[REDACTED]"
    static let safeEnvironmentFeatureNames: Set<String> = [
        "SHELL", "TERM", "LANG", "PWD", "VIRTUAL_ENV"
    ]

    func sanitizeCommand(_ command: String) -> SanitizedValue { sanitize(command) }
    func sanitizeOutput(_ output: String) -> SanitizedValue { sanitize(output) }
    func sanitizeError(_ error: String) -> SanitizedValue { sanitize(error) }

    func sanitizeEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.reduce(into: [:]) { partial, entry in
            guard Self.safeEnvironmentFeatureNames.contains(entry.key) else { return }
            let sanitized = sanitize(entry.value)
            guard sanitized.redactionCount == 0 else { return }
            partial[entry.key] = sanitized.value
        }
    }

    func containsSensitiveData(_ text: String) -> Bool {
        sanitize(text).redactionCount > 0
    }

    private func sanitize(_ text: String) -> SanitizedValue {
        var value = text
        var categories: Set<SensitiveDataCategory> = []
        var count = 0

        func replace(_ pattern: String, category: SensitiveDataCategory, template: String = "$1[REDACTED]") {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { return }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            let matches = regex.matches(in: value, range: range)
            guard !matches.isEmpty else { return }
            value = regex.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: template
            )
            count += matches.count
            categories.insert(category)
        }

        replace(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, category: .privateKey, template: Self.redaction)
        replace(#"((?:Authorization\s*:\s*)?Bearer\s+)[A-Za-z0-9._~+/=-]{6,}"#, category: .authorizationHeader)
        replace(#"((?:password|passwd|passphrase|pwd)\s*(?:=|:)\s*)[^\s'\"]+"#, category: .password)
        replace(#"(--(?:password|passwd|passphrase)(?:=|\s+))[^\s'\"]+"#, category: .password)
        replace(#"((?:api[_-]?key|access[_-]?token|refresh[_-]?token|secret[_-]?access[_-]?key|client[_-]?secret)\s*(?:=|:)\s*)[^\s'\"]+"#, category: .apiKey)
        replace(#"((?:OPENAI_API_KEY|AWS_SECRET_ACCESS_KEY|GITHUB_TOKEN|GH_TOKEN|NPM_TOKEN|DATABASE_URL)\s*=\s*)[^\s'\"]+"#, category: .environmentValue)
        replace(#"((?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis)://[^:\s/@]+:)[^@\s]+(@)"#, category: .connectionString, template: "$1[REDACTED]$2")
        replace(#"((?:Cookie|Set-Cookie)\s*:\s*)[^\r\n]+"#, category: .sessionCookie)
        replace(#"((?:sk|ghp|github_pat|xox[baprs])-)[A-Za-z0-9_\-]{8,}"#, category: .apiKey)

        return SanitizedValue(value: value, redactionCount: count, categories: categories)
    }
}
