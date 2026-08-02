import Foundation
import XCTest
@testable import Pane

final class CommandAutocompleteTests: XCTestCase {
    func testCompletionSourceMappingCoversEverySource() {
        let expected: [CompletionSource: CommandAutocompleteSuggestion.Source] = [
            .zsh: .zsh, .history: .history, .builtIn: .builtIn,
            .executable: .executable, .fileSystem: .fileSystem,
            .projectScript: .projectScript, .projectCommand: .projectScript,
            .transition: .transition
        ]
        XCTAssertEqual(Set(expected.keys), Set(CompletionSource.allCases))
        for (candidate, suggestion) in expected {
            XCTAssertEqual(
                CompletionSourceMapping.suggestionSource(from: candidate),
                suggestion
            )
        }

        let suggestionSources: [CommandAutocompleteSuggestion.Source] = [
            .zsh, .history, .builtIn, .executable, .fileSystem,
            .projectScript, .transition
        ]
        for suggestion in suggestionSources {
            let candidate = CompletionSourceMapping.candidateSource(from: suggestion)
            XCTAssertEqual(
                CompletionSourceMapping.suggestionSource(from: candidate),
                suggestion
            )
        }
    }
    let home = "/Users/tester"

    func makeCompletionRequest(generation: UInt64, draft: String = "git",
                               tokenRange: NSRange = NSRange(location: 0, length: 3)) -> CompletionRequest {
        CompletionRequest(
            id: UUID(),
            generation: generation,
            draft: draft,
            cursorUTF16Offset: (draft as NSString).length,
            tokenContext: CommandTokenContext(
                replacementRange: tokenRange,
                decodedPrefix: "git",
                isCommandPosition: true
            ),
            currentDirectory: FileManager.default.temporaryDirectory,
            projectContext: nil,
            previousCommand: nil,
            executableSearchPath: "",
            shellGeneration: 1,
            maximumResults: 12,
            createdAt: ContinuousClock.now
        )
    }

    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PaneAutocompleteTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    func makeExecutable(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    func initializeGitRepository(at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--quiet", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

struct FakeCompletionProvider: CompletionProvider {
    let identifier: CompletionProviderID
    let delay: Duration
    let values: [CompletionCandidate]

    func candidates(for request: CompletionRequest) async throws -> [CompletionCandidate] {
        if delay != .zero { try await Task.sleep(for: delay) }
        return values
    }
}

actor AsyncCounter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
