import Foundation
import XCTest
@testable import Pane

extension CommandAutocompleteTests {
    func testProjectContextFindsNestedPackageScriptsAndMakeTargets() async throws {
        let root = try makeTemporaryDirectory()
        let nested = root.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(
            #"{"scripts":{"test":"vitest","dev":"vite"}}"#.utf8
        ).write(to: root.appendingPathComponent("package.json"))
        try Data("build:\n\t@echo build\nclean:\n\t@echo clean\n".utf8)
            .write(to: root.appendingPathComponent("Makefile"))

        let provider = ProjectContextProvider()
        let discoveredContext = await provider.context(for: nested)
        let context = try XCTUnwrap(discoveredContext)

        XCTAssertEqual(context.root.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(context.kind, .node)
        XCTAssertTrue(context.detectedLanguages.contains(.javaScript))
        XCTAssertEqual(
            Set(context.scripts.map(\.command)),
            ["npm run dev", "npm run test", "make build", "make clean"]
        )
        let discoveredRootContext = await provider.context(for: root)
        let rootContext = try XCTUnwrap(discoveredRootContext)
        XCTAssertEqual(
            context.identity,
            rootContext.identity
        )
    }

    func testBoundedProcessOutputStopsMonitoringAtEOF() throws {
        let pipe = Pipe()
        let output = BoundedProcessOutput(maximumBytes: 128)
        pipe.fileHandleForReading.readabilityHandler = { _ in }
        try pipe.fileHandleForWriting.close()

        XCTAssertFalse(output.drainAvailableData(from: pipe.fileHandleForReading))
        XCTAssertNil(pipe.fileHandleForReading.readabilityHandler)
    }

    func testGitContextStopsReadingWhenEmptyRemoteOutputReachesEOF() async throws {
        let root = try makeTemporaryDirectory()
        try initializeGitRepository(at: root)
        let provider = ProjectContextProvider()
        let clock = ContinuousClock()
        let startedAt = clock.now

        let context = await provider.gitContext(root: root)

        XCTAssertNotNil(context)
        XCTAssertEqual(context?.remoteNames, [])
        XCTAssertLessThan(
            startedAt.duration(to: clock.now),
            .seconds(2),
            "An empty Git stdout pipe must reach EOF without spinning"
        )
    }

    func testProjectDefinitionAndGitCachesHaveIndependentFreshness() async throws {
        let root = try makeTemporaryDirectory()
        let manifest = root.appendingPathComponent("Package.swift")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: manifest.path,
            contents: Data("// package".utf8)
        ))
        let provider = ProjectContextProvider()
        let definitionCache = ProjectDefinitionCache(ttl: 300)
        let definitionLoads = AsyncCounter()

        let first = await definitionCache.value(for: root) {
            await definitionLoads.increment()
            return provider.definition(for: root)
        }
        let second = await definitionCache.value(for: root) {
            await definitionLoads.increment()
            return provider.definition(for: root)
        }
        XCTAssertEqual(first?.identity, second?.identity)
        let initialDefinitionLoads = await definitionLoads.value
        XCTAssertEqual(initialDefinitionLoads, 1)

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: manifest.path
        )
        _ = await definitionCache.value(for: root) {
            await definitionLoads.increment()
            return provider.definition(for: root)
        }
        let refreshedDefinitionLoads = await definitionLoads.value
        XCTAssertEqual(refreshedDefinitionLoads, 2)

        let gitCache = GitContextCache(activeTTL: 30)
        let gitLoads = AsyncCounter()
        let loadGit: @Sendable () async -> GitContext? = {
            let count = await gitLoads.increment()
            return GitContext(
                root: root,
                branch: "branch-\(count)",
                headOID: nil,
                isDirty: false,
                hasStagedChanges: false,
                remoteNames: []
            )
        }
        let cachedGit = await gitCache.value(for: root, loader: loadGit)
        let stillCached = await gitCache.value(for: root, loader: loadGit)
        XCTAssertEqual(cachedGit?.branch, stillCached?.branch)
        await gitCache.invalidate(root: root)
        let refreshedGit = await gitCache.value(for: root, loader: loadGit)
        XCTAssertEqual(refreshedGit?.branch, "branch-2")
    }

    func testLocalProviderCompletesProjectScriptWithoutDuplicatingCommandPrefix() async throws {
        let root = try makeTemporaryDirectory()
        try Data(
            #"{"scripts":{"test":"vitest","typecheck":"tsc --noEmit"}}"#.utf8
        ).write(to: root.appendingPathComponent("package.json"))
        let provider = LocalAutocompleteProvider(maximumSuggestions: 12)
        let context = LocalAutocompleteContext(
            draft: "npm r",
            cursorUTF16Offset: 5,
            history: [],
            currentDirectory: root,
            executableSearchPath: "",
            shellGeneration: 1
        )

        let suggestions = await provider.suggestions(for: context)
        let test = try XCTUnwrap(suggestions.first {
            $0.source == .projectScript && $0.text == "npm run test"
        })
        let edit = CommandAutocomplete().accept(test, in: "npm r")

        XCTAssertEqual(test.replacementText, "run test")
        XCTAssertEqual(test.detail, "package.json")
        XCTAssertEqual(edit.draft, "npm run test")
    }

}
