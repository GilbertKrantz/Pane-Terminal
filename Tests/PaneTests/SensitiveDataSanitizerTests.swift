import XCTest
@testable import Pane

final class SensitiveDataSanitizerTests: XCTestCase {
    private let sanitizer = SensitiveDataSanitizer()

    func testRedactsSecretCommandArgumentsAndEnvironmentAssignments() {
        let command = "export OPENAI_API_KEY=sk-example-secret && mysql --password=my-password"

        let sanitized = sanitizer.sanitizeCommand(command)

        XCTAssertFalse(sanitized.value.contains("sk-example-secret"))
        XCTAssertFalse(sanitized.value.contains("my-password"))
        XCTAssertTrue(sanitized.value.contains("OPENAI_API_KEY=[REDACTED]"))
        XCTAssertTrue(sanitized.value.contains("--password=[REDACTED]"))
        XCTAssertGreaterThanOrEqual(sanitized.redactionCount, 2)
    }

    func testRedactsAuthorizationHeadersAndDatabaseURLs() {
        let output = "curl -H 'Authorization: Bearer abc123secret' postgresql://user:password@localhost/db"

        let sanitized = sanitizer.sanitizeOutput(output)

        XCTAssertFalse(sanitized.value.contains("abc123secret"))
        XCTAssertFalse(sanitized.value.contains("user:password@"))
        XCTAssertTrue(sanitized.value.contains("Bearer [REDACTED]"))
        XCTAssertTrue(sanitized.value.contains("postgresql://user:[REDACTED]@localhost/db"))
    }

    func testRedactsPrivateKeys() {
        let key = "-----BEGIN PRIVATE KEY-----\nsecret material\n-----END PRIVATE KEY-----"

        let sanitized = sanitizer.sanitizeError(key)

        XCTAssertEqual(sanitized.value, "[REDACTED]")
        XCTAssertTrue(sanitized.categories.contains(.privateKey))
    }

    func testEnvironmentSanitizationUsesAllowlistAndDropsSensitiveValues() {
        let environment = [
            "SHELL": "/bin/zsh",
            "OPENAI_API_KEY": "sk-example-secret",
            "PATH": "/usr/bin",
            "TERM": "xterm-256color"
        ]

        let sanitized = sanitizer.sanitizeEnvironment(environment)

        XCTAssertEqual(sanitized["SHELL"], "/bin/zsh")
        XCTAssertEqual(sanitized["TERM"], "xterm-256color")
        XCTAssertNil(sanitized["OPENAI_API_KEY"])
        XCTAssertNil(sanitized["PATH"])
    }

    func testOrdinaryCommandsArePreserved() {
        let command = "swift test --filter CommandHistoryTests"

        let sanitized = sanitizer.sanitizeCommand(command)

        XCTAssertEqual(sanitized.value, command)
        XCTAssertEqual(sanitized.redactionCount, 0)
    }

    @MainActor
    func testTerminalSessionHistoryNeverRetainsSecretCommandArguments() {
        let session = TerminalSession()
        let secret = "sk-history-secret-123456"

        session.submit(command: "export OPENAI_API_KEY=\(secret)")

        XCTAssertFalse(session.history.commands.joined().contains(secret))
        XCTAssertTrue(session.history.commands.isEmpty)
    }
}
