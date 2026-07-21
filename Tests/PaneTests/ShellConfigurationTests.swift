import XCTest
@testable import Pane

final class ShellConfigurationTests: XCTestCase {
    func testLoginShellUsesExpectedExecutableAndTerminalEnvironment() {
        let configuration = ShellConfiguration.loginZsh(
            processEnvironment: ["PATH": "/usr/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp/example-home")
        )

        XCTAssertEqual(configuration.executable, "/bin/zsh")
        XCTAssertEqual(configuration.arguments, ["-l", "-i"])
        XCTAssertEqual(configuration.workingDirectory, "/tmp/example-home")
        XCTAssertTrue(configuration.environment.contains("TERM=xterm-256color"))
        XCTAssertTrue(configuration.environment.contains("COLORTERM=truecolor"))
        XCTAssertTrue(configuration.environment.contains("PANE_BLOCKS=1"))
        XCTAssertTrue(configuration.environment.contains("PATH=/usr/bin"))
    }

    func testPreservesZDotDirectoryForOhMyZshConfiguration() {
        let configuration = ShellConfiguration.loginZsh(
            processEnvironment: [
                "HOME": "/Users/example",
                "ZDOTDIR": "/Users/example/.config/zsh"
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/example")
        )

        XCTAssertTrue(configuration.environment.contains("ZDOTDIR=/Users/example/.config/zsh"))
        XCTAssertEqual(configuration.arguments, ["-l", "-i"])
    }
}
