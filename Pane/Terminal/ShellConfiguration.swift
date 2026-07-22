import Foundation

struct ShellConfiguration: Equatable, Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String]
    var workingDirectory: String

    static func loginZsh(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ShellConfiguration {
        var environment = processEnvironment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Pane"
        environment["TERM_PROGRAM_VERSION"] = "0.2"
        environment["PANE_BLOCKS"] = "1"

        return ShellConfiguration(
            executable: "/bin/zsh",
            // Explicit interactive + login flags guarantee that ~/.zshrc (or
            // $ZDOTDIR/.zshrc) is loaded, including Oh My Zsh initialization.
            arguments: ["-l", "-i"],
            environment: environment
                .map { "\($0.key)=\($0.value)" }
                .sorted(),
            workingDirectory: homeDirectory.path
        )
    }
}
