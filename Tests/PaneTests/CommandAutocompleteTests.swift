import Foundation
import XCTest
@testable import Pane

final class CommandAutocompleteTests: XCTestCase {
    private let home = "/Users/tester"

    func testProjectNameTakesPriorityOverFolderName() {
        let project = presentationProject(root: "/Users/tester/Projects/Pane")
        let value = ComposerContextPresentation.make(
            directoryPath: "/Users/tester/Projects/Pane/Sources", project: project, homePath: home
        )
        XCTAssertEqual(value.displayName, "Pane")
        XCTAssertEqual(value.iconName, "folder")
    }

    func testFolderNameUsedWithoutProject() {
        XCTAssertEqual(presentation(path: "/Users/tester/Downloads").displayName, "Downloads")
    }

    func testHomeDirectoryDisplaysHome() {
        let value = presentation(path: home)
        XCTAssertEqual(value.displayName, "Home")
        XCTAssertEqual(value.iconName, "folder")
    }

    func testRootDirectoryDisplaysSlash() {
        let value = presentation(path: "/")
        XCTAssertEqual(value.displayName, "/")
        XCTAssertEqual(value.iconName, "folder")
    }

    func testTooltipIncludesBranch() {
        let value = ComposerContextPresentation.make(
            directoryPath: "/Users/tester/Projects/Pane",
            project: presentationProject(root: "/Users/tester/Projects/Pane", branch: "feature/chip"),
            homePath: home
        )
        XCTAssertEqual(value.tooltipText, "~/Projects/Pane\nBranch: feature/chip")
        XCTAssertTrue(value.accessibilityLabel.contains("branch feature/chip"))
    }

    func testLongBranchIsTruncatedOnlyInTooltip() {
        let branch = "feature/" + String(repeating: "context-chip-", count: 14)
        let value = ComposerContextPresentation.make(
            directoryPath: "/Users/tester/Projects/Pane",
            project: presentationProject(root: "/Users/tester/Projects/Pane", branch: branch),
            homePath: home
        )

        XCTAssertEqual(value.branchName, branch)
        XCTAssertTrue(value.tooltipText.contains("…"))
        XCTAssertFalse(value.tooltipText.contains(branch))
    }

    func testTooltipOmitsBranchOutsideGitRepository() {
        let value = presentation(path: "/Users/tester/Downloads")
        XCTAssertEqual(value.tooltipText, "~/Downloads")
        XCTAssertNil(value.branchName)
    }

    func testDetachedHeadTooltip() {
        let project = presentationProject(root: "/Users/tester/Pane", branch: nil)
        XCTAssertEqual(
            ComposerContextPresentation.make(directoryPath: project.root.path, project: project, homePath: home).tooltipText,
            "~/Pane\nDetached HEAD"
        )
        XCTAssertNil(
            ComposerContextPresentation.make(
                directoryPath: project.root.path, project: project, homePath: home
            ).branchName
        )
    }

    func testFullPathUsesTildeForDisplay() {
        let value = presentation(path: "/Users/tester/Documents/Work")
        XCTAssertEqual(value.tooltipText, "~/Documents/Work")
        XCTAssertEqual(value.fullPath, "/Users/tester/Documents/Work")
    }

    func testCopyPathCopiesAbsolutePath() {
        let value = presentation(path: "/Users/tester/Documents/Work")
        let menu = menuPresentation(value, existingPaths: [value.fullPath])

        XCTAssertEqual(menu.copyPath, "/Users/tester/Documents/Work")
    }

    func testCopyBranchCopiesOnlyBranchName() {
        let value = ComposerContextPresentation.make(
            directoryPath: "/Users/tester/Pane",
            project: presentationProject(root: "/Users/tester/Pane", branch: "feature/chip"),
            homePath: home
        )

        XCTAssertEqual(menuPresentation(value).copyBranchName, "feature/chip")
    }

    func testCopyBranchHiddenWithoutBranch() {
        XCTAssertNil(menuPresentation(presentation(path: "/Users/tester/Downloads")).copyBranchName)
    }

    func testOpenInFinderDisabledForMissingDirectory() {
        let value = presentation(path: "/Users/tester/Missing")

        XCTAssertNil(menuPresentation(value).openInFinderURL)
    }

    func testComposerContextResponsiveLayoutUsesLargeTextCapAt500Points() {
        let layout = ComposerContextLayout.make(availableWidth: 500)

        XCTAssertTrue(layout.showsName)
        XCTAssertEqual(layout.textMaxWidth, 240)
    }

    func testComposerContextResponsiveLayoutUsesMediumTextCapBelow500Points() {
        let layout = ComposerContextLayout.make(availableWidth: 499)

        XCTAssertTrue(layout.showsName)
        XCTAssertEqual(layout.textMaxWidth, 160)
    }

    func testComposerContextResponsiveLayoutStillShowsNameAt320Points() {
        let layout = ComposerContextLayout.make(availableWidth: 320)

        XCTAssertTrue(layout.showsName)
        XCTAssertEqual(layout.textMaxWidth, 160)
    }

    func testComposerContextResponsiveLayoutUsesIconOnlyBelow320Points() {
        let layout = ComposerContextLayout.make(availableWidth: 319)

        XCTAssertFalse(layout.showsName)
        XCTAssertNil(layout.textMaxWidth)
    }

    func testComposerIdleLayoutIsACompactTwoStoryStack() {
        XCTAssertEqual(PaneMetrics.composerHorizontalInset, 20)
        XCTAssertEqual(PaneMetrics.composerOuterVerticalInset, 6)
        XCTAssertEqual(PaneMetrics.composerContextHeaderHeight, 16)
        XCTAssertEqual(PaneMetrics.composerContextEditorGap, 2)
        XCTAssertEqual(PaneMetrics.composerEditorMinHeight, 28)
        XCTAssertEqual(PaneMetrics.composerEditorSubmitSpacing, 8)
        XCTAssertEqual(PaneMetrics.composerSubmitButtonSize, 28)
        XCTAssertEqual(
            (PaneMetrics.composerOuterVerticalInset * 2)
                + PaneMetrics.composerContextHeaderHeight
                + PaneMetrics.composerContextEditorGap
                + PaneMetrics.composerEditorMinHeight,
            PaneMetrics.composerMinHeight
        )

        let idleStackHeight = PaneMetrics.composerContextHeaderHeight
            + PaneMetrics.composerContextEditorGap
            + PaneMetrics.composerEditorMinHeight
        let centeredSubmitInset = (idleStackHeight - PaneMetrics.composerSubmitButtonSize) / 2
        XCTAssertEqual(centeredSubmitInset, 9)
    }

    private func presentation(path: String) -> ComposerContextPresentation {
        .make(directoryPath: path, project: nil, homePath: home)
    }

    private func menuPresentation(
        _ context: ComposerContextPresentation,
        existingPaths: Set<String> = []
    ) -> ComposerContextMenuPresentation {
        .make(context: context, directoryExists: existingPaths.contains)
    }

    private func presentationProject(root: String, branch: String? = "main") -> ProjectContext {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        return ProjectContext(
            root: url, identity: "test", kind: .git,
            git: GitContext(root: url, branch: branch, headOID: "abc", isDirty: false,
                            hasStagedChanges: false, remoteNames: []),
            manifests: [], scripts: [], detectedLanguages: [], discoveredAt: Date()
        )
    }

    func testCompletionRankerMergesEvidenceAndPrefersProjectProvider() {
        var historyEvidence = CompletionEvidence()
        historyEvidence.sessionFrequency = 4
        var projectEvidence = CompletionEvidence()
        projectEvidence.projectMatch = true
        projectEvidence.workingDirectoryMatch = true

        let ranked = CompletionRanker().rank([
            CompletionCandidate(
                displayText: "npm run test",
                replacementText: "npm run test",
                source: .history,
                kind: .fullCommand,
                evidence: historyEvidence
            ),
            CompletionCandidate(
                displayText: "npm run test",
                replacementText: "npm run test",
                source: .projectScript,
                kind: .fullCommand,
                detail: "package.json",
                evidence: projectEvidence
            )
        ])

        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked[0].candidate.source, .projectScript)
        XCTAssertEqual(ranked[0].candidate.detail, "package.json")
        XCTAssertEqual(ranked[0].candidate.evidence.sessionFrequency, 4)
        XCTAssertTrue(ranked[0].candidate.evidence.projectMatch)
    }

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

    func testHistorySuggestionsUseCurrentSessionRecencyAndCommandContext() throws {
        let currentDirectory = try makeTemporaryDirectory()
        let autocomplete = CommandAutocomplete(
            maximumSuggestions: 10,
            builtInCommands: []
        )

        let suggestions = autocomplete.suggestions(
            for: "git st",
            history: [
                "git stash",
                "git status --short",
                "git store"
            ],
            currentDirectory: currentDirectory,
            executableSearchPath: ""
        )

        XCTAssertEqual(suggestions.map(\.text), ["store", "status", "stash"])
        XCTAssertEqual(suggestions.map(\.source), [.history, .history, .history])
    }

    func testAcceptingFullCommandHistoryReplacesDraftInsteadOfDuplicatingPrefix() {
        let autocomplete = CommandAutocomplete()
        let suggestion = CommandAutocompleteSuggestion(
            text: "cd Documents/Work/repo-github/",
            replacementText: "cd Documents/Work/repo-github/",
            replacementRange: NSRange(location: 0, length: 4),
            source: .history,
            detail: "Command history"
        )

        let edit = autocomplete.accept(
            suggestion,
            in: "cd D",
            cursorUTF16Offset: 4
        )

        XCTAssertEqual(edit.draft, "cd Documents/Work/repo-github/")
        XCTAssertEqual(
            edit.cursorUTF16Offset,
            ("cd Documents/Work/repo-github/" as NSString).length
        )
    }

    func testFullCommandHistoryCarriesWholeDraftReplacementRange() async throws {
        let directory = try makeTemporaryDirectory()
        let provider = LocalAutocompleteProvider(maximumSuggestions: 12)
        let draft = "cd D"
        let suggestions = await provider.suggestions(
            for: LocalAutocompleteContext(
                draft: draft,
                cursorUTF16Offset: (draft as NSString).length,
                history: ["cd Documents/Work/repo-github/"],
                currentDirectory: directory,
                executableSearchPath: "",
                shellGeneration: 1
            )
        )
        let suggestion = try XCTUnwrap(suggestions.first {
            $0.replacementText == "cd Documents/Work/repo-github/"
        })

        XCTAssertEqual(
            suggestion.replacementRange,
            NSRange(location: 0, length: (draft as NSString).length)
        )
        XCTAssertEqual(
            CommandAutocomplete().accept(suggestion, in: draft).draft,
            "cd Documents/Work/repo-github/"
        )
    }

    func testAcceptingTokenHistoryStillReplacesOnlyCurrentToken() {
        let autocomplete = CommandAutocomplete()
        let suggestion = CommandAutocompleteSuggestion(
            text: "status",
            replacementText: "status",
            source: .history
        )

        let edit = autocomplete.accept(
            suggestion,
            in: "git st --short",
            cursorUTF16Offset: 6
        )

        XCTAssertEqual(edit.draft, "git status --short")
        XCTAssertEqual(edit.cursorUTF16Offset, 10)
    }

    func testHistorySuggestionsSupportMultilineDrafts() throws {
        let currentDirectory = try makeTemporaryDirectory()
        let autocomplete = CommandAutocomplete(builtInCommands: [])

        let suggestions = autocomplete.suggestions(
            for: "echo first\ncat ph",
            history: ["echo first\ncat photo.png"],
            currentDirectory: currentDirectory,
            executableSearchPath: ""
        )

        XCTAssertEqual(suggestions.map(\.text), ["photo.png"])
        let edit = autocomplete.accept(suggestions[0], in: "echo first\ncat ph")
        XCTAssertEqual(edit.draft, "echo first\ncat photo.png")
    }

    func testBuiltInsAreDeterministicAndResultCountIsCapped() throws {
        let currentDirectory = try makeTemporaryDirectory()
        let autocomplete = CommandAutocomplete(
            maximumSuggestions: 2,
            builtInCommands: ["garden", "gamut", "gamma", "gamma"]
        )

        let suggestions = autocomplete.suggestions(
            for: "ga",
            history: [],
            currentDirectory: currentDirectory,
            executableSearchPath: ""
        )

        XCTAssertEqual(suggestions.map(\.text), ["gamma", "gamut"])
        XCTAssertEqual(suggestions.map(\.source), [.builtIn, .builtIn])
    }

    func testPATHSuggestionsIncludeOnlyExecutableFilesAndDeduplicateNames() throws {
        let currentDirectory = try makeTemporaryDirectory()
        let firstBin = currentDirectory.appendingPathComponent("first-bin", isDirectory: true)
        let secondBin = currentDirectory.appendingPathComponent("second-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: firstBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondBin, withIntermediateDirectories: true)

        try makeExecutable(named: "pane", in: firstBin)
        try makeExecutable(named: "pane-tool", in: firstBin)
        try makeExecutable(named: "pane", in: secondBin)
        _ = FileManager.default.createFile(
            atPath: secondBin.appendingPathComponent("panec").path,
            contents: Data()
        )
        try FileManager.default.createDirectory(
            at: secondBin.appendingPathComponent("pane-directory"),
            withIntermediateDirectories: false
        )

        let autocomplete = CommandAutocomplete(builtInCommands: [])
        let suggestions = autocomplete.suggestions(
            for: "pan",
            history: [],
            currentDirectory: currentDirectory,
            executableSearchPath: "second-bin:first-bin"
        )

        XCTAssertEqual(suggestions.map(\.text), ["pane", "pane-tool"])
        XCTAssertEqual(suggestions.map(\.source), [.executable, .executable])
    }

    func testExecutablesAreOnlySuggestedAtACommandPosition() throws {
        let currentDirectory = try makeTemporaryDirectory()
        let bin = currentDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try makeExecutable(named: "git", in: bin)

        let suggestions = CommandAutocomplete(builtInCommands: []).suggestions(
            for: "echo gi",
            history: [],
            currentDirectory: currentDirectory,
            executableSearchPath: "bin"
        )

        XCTAssertFalse(suggestions.contains { $0.source == .executable })
    }

    func testFileSystemSuggestionsResolveAgainstProvidedCurrentDirectory() throws {
        let currentDirectory = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: currentDirectory.appendingPathComponent("Documents"),
            withIntermediateDirectories: false
        )
        _ = FileManager.default.createFile(
            atPath: currentDirectory.appendingPathComponent("Dockerfile").path,
            contents: Data()
        )
        _ = FileManager.default.createFile(
            atPath: currentDirectory.appendingPathComponent(".dotfile").path,
            contents: Data()
        )

        let suggestions = CommandAutocomplete(builtInCommands: []).suggestions(
            for: "cat Do",
            history: [],
            currentDirectory: currentDirectory,
            executableSearchPath: ""
        )

        XCTAssertEqual(suggestions.map(\.text), ["Dockerfile", "Documents/"])
        XCTAssertEqual(suggestions.map(\.source), [.fileSystem, .fileSystem])
        XCTAssertFalse(suggestions[0].isDirectory)
        XCTAssertTrue(suggestions[1].isDirectory)
    }

    func testAcceptEscapesPathSpaces() throws {
        let currentDirectory = try makeTemporaryDirectory()
        _ = FileManager.default.createFile(
            atPath: currentDirectory.appendingPathComponent("My File.txt").path,
            contents: Data()
        )
        let autocomplete = CommandAutocomplete(builtInCommands: [])
        let suggestions = autocomplete.suggestions(
            for: "cat My",
            history: [],
            currentDirectory: currentDirectory,
            executableSearchPath: ""
        )

        XCTAssertEqual(suggestions.map(\.text), ["My File.txt"])
        XCTAssertEqual(suggestions[0].replacementText, "My\\ File.txt")
        XCTAssertEqual(
            autocomplete.accept(suggestions[0], in: "cat My").draft,
            "cat My\\ File.txt"
        )
    }

    func testAcceptReplacesOnlyCurrentTokenAndPreservesMultilineDraft() {
        let autocomplete = CommandAutocomplete()
        let draft = "echo first\ncat old.txt --flag"
        let tokenRange = (draft as NSString).range(of: "old.txt")
        let cursor = tokenRange.location + 3
        let suggestion = CommandAutocompleteSuggestion(
            text: "new.txt",
            source: .fileSystem
        )

        let edit = autocomplete.accept(
            suggestion,
            in: draft,
            cursorUTF16Offset: cursor
        )

        XCTAssertEqual(edit.draft, "echo first\ncat new.txt --flag")
        XCTAssertEqual(
            edit.cursorUTF16Offset,
            tokenRange.location + ("new.txt" as NSString).length
        )
    }

    func testCapturedSuggestionsPreserveCompsysContext() {
        let candidates = [
            ZshCompletionCandidate(
                replacementText: "--verbose",
                detail: "Print additional progress",
                isDirectory: false
            ),
            ZshCompletionCandidate(
                replacementText: "checkout",
                detail: "Switch branches or restore working tree files",
                isDirectory: false
            ),
            ZshCompletionCandidate(
                replacementText: "Sources/",
                detail: nil,
                isDirectory: true
            )
        ]

        let suggestions = CommandAutocomplete().capturedSuggestions(candidates)

        XCTAssertEqual(suggestions.map(\.source), [.zsh, .zsh, .zsh])
        XCTAssertEqual(suggestions.map(\.replacementText), ["--verbose", "checkout", "Sources/"])
        XCTAssertEqual(
            suggestions.map(\.detail),
            [
                "Print additional progress",
                "Switch branches or restore working tree files",
                nil
            ]
        )
        XCTAssertFalse(suggestions[0].isDirectory)
        XCTAssertTrue(suggestions[2].isDirectory)
    }

    func testKeyboardSelectionCyclesWithoutChangingSuggestionOrder() {
        let suggestions = [
            CommandAutocompleteSuggestion(text: "checkout", source: .zsh),
            CommandAutocompleteSuggestion(text: "cherry-pick", source: .zsh),
            CommandAutocompleteSuggestion(text: "clean", source: .zsh)
        ]
        var selection = CommandAutocompleteSelection()

        XCTAssertTrue(selection.move(by: 1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "checkout")
        XCTAssertTrue(selection.move(by: 1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "cherry-pick")
        XCTAssertTrue(selection.move(by: 1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "clean")
        XCTAssertTrue(selection.move(by: 1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "checkout")
    }

    func testSingleSuggestionRequiresTwoTabsBeforeAccepting() {
        let suggestion = CommandAutocompleteSuggestion(text: "status", source: .zsh)
        let suggestions = [suggestion]
        var selection = CommandAutocompleteSelection()

        XCTAssertNil(selection.selected(from: suggestions))
        XCTAssertEqual(selection.handleTab(by: 1, through: suggestions), .cycle)
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "status")
        XCTAssertEqual(
            selection.handleTab(by: 1, through: suggestions),
            .accept(suggestion)
        )
        XCTAssertNil(selection.selected(from: suggestions))
    }

    func testKeyboardSelectionMovesBackwardAndResetsForEmptyResults() {
        let suggestions = [
            CommandAutocompleteSuggestion(text: "main", source: .zsh),
            CommandAutocompleteSuggestion(text: "master", source: .zsh)
        ]
        var selection = CommandAutocompleteSelection()

        XCTAssertTrue(selection.move(by: -1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "master")
        XCTAssertTrue(selection.move(by: -1, through: suggestions))
        XCTAssertEqual(selection.selected(from: suggestions)?.text, "main")
        XCTAssertFalse(selection.move(by: 1, through: []))
        XCTAssertNil(selection.highlightedSuggestionID)
    }

    func testCapturedSuggestionsAreDeduplicatedAndCappedWithoutReordering() {
        let candidates = (0..<20).map { index in
            ZshCompletionCandidate(
                replacementText: index == 1 ? "match-0" : "match-\(index)",
                detail: "detail-\(index)",
                isDirectory: false
            )
        }

        let suggestions = CommandAutocomplete(maximumSuggestions: 3)
            .capturedSuggestions(candidates)

        XCTAssertEqual(suggestions.map(\.replacementText), ["match-0", "match-2", "match-3"])
        XCTAssertEqual(suggestions.map(\.detail), ["detail-0", "detail-2", "detail-3"])
    }

    func testExecutableIndexInvalidatesWhenPATHChanges() async throws {
        let root = try makeTemporaryDirectory()
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try makeExecutable(named: "pane-first", in: first)
        try makeExecutable(named: "pane-second", in: second)
        let index = ExecutableIndex(ttl: 120)

        let initial = await index.candidates(prefix: "pane-", path: first.path, currentDirectory: root, shellGeneration: 1)
        let changed = await index.candidates(prefix: "pane-", path: second.path, currentDirectory: root, shellGeneration: 1)

        XCTAssertEqual(initial, ["pane-first"])
        XCTAssertEqual(changed, ["pane-second"])
    }

    func testExecutableIndexDoesNotReuseRelativePATHAcrossDirectories() async throws {
        let firstCWD = try makeTemporaryDirectory()
        let secondCWD = try makeTemporaryDirectory()
        try makeExecutable(named: "cwd-first", in: firstCWD)
        try makeExecutable(named: "cwd-second", in: secondCWD)
        let index = ExecutableIndex(ttl: 120)

        let first = await index.candidates(prefix: "cwd-", path: "", currentDirectory: firstCWD, shellGeneration: 1)
        let second = await index.candidates(prefix: "cwd-", path: "", currentDirectory: secondCWD, shellGeneration: 1)

        XCTAssertEqual(first, ["cwd-first"])
        XCTAssertEqual(second, ["cwd-second"])
    }

    func testCompletionServicePublishesLocalThenMergesValidZsh() async throws {
        let directory = try makeTemporaryDirectory()
        let context = LocalAutocompleteContext(
            draft: "gi",
            cursorUTF16Offset: 2,
            history: ["git status"],
            currentDirectory: directory,
            executableSearchPath: "",
            shellGeneration: 1
        )
        let service = CompletionService()
        let updates = await service.suggestions(for: context) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            return ZshCompletionProtocol.Response(
                requestID: "request-1",
                status: .ok,
                candidates: [
                    .init(
                        replacementText: "git-from-zsh",
                        detail: "zsh",
                        isDirectory: false
                    )
                ]
            )
        }

        var received: [[CommandAutocompleteSuggestion]] = []
        for await update in updates {
            received.append(update)
        }

        XCTAssertGreaterThanOrEqual(received.count, 2)
        XCTAssertFalse(received[0].isEmpty)
        XCTAssertEqual(received.last?.first?.replacementText, "git-from-zsh")
        XCTAssertTrue(received.last?.contains { $0.replacementText == "git status" } == true)
    }

    func testCompletionServicePreservesWholeDraftEditForPartialHistoryPrefix() async throws {
        let directory = try makeTemporaryDirectory()
        let draft = "cd D"
        let context = LocalAutocompleteContext(
            draft: draft,
            cursorUTF16Offset: (draft as NSString).length,
            history: ["cd Documents/Work/Repo-gitlab/airflow-dags"],
            currentDirectory: directory,
            executableSearchPath: "",
            shellGeneration: 1
        )
        let service = CompletionService()
        let updates = await service.suggestions(for: context) {
            ZshCompletionProtocol.Response(
                requestID: "range-check",
                status: .ok,
                candidates: []
            )
        }

        var finalSuggestions: [CommandAutocompleteSuggestion] = []
        for await update in updates {
            finalSuggestions = update
        }
        let suggestion = try XCTUnwrap(finalSuggestions.first {
            CommandAutocomplete().accept($0, in: draft).draft
                == "cd Documents/Work/Repo-gitlab/airflow-dags"
        }, "Published replacements: \(finalSuggestions.map(\.replacementText))")

        XCTAssertEqual(suggestion.id,
                       "typedCompletion|false|cd Documents/Work/Repo-gitlab/airflow-dags")
        XCTAssertEqual(
            CommandAutocomplete().accept(suggestion, in: draft).draft,
            "cd Documents/Work/Repo-gitlab/airflow-dags"
        )
    }

    func testCompletionServiceTreatsValidEmptyZshAsAnEmptyContribution() async throws {
        let directory = try makeTemporaryDirectory()
        let context = LocalAutocompleteContext(
            draft: "gi",
            cursorUTF16Offset: 2,
            history: ["git status"],
            currentDirectory: directory,
            executableSearchPath: "",
            shellGeneration: 1
        )
        let service = CompletionService()
        let updates = await service.suggestions(for: context) {
            ZshCompletionProtocol.Response(
                requestID: "request-2",
                status: .ok,
                candidates: []
            )
        }

        var final: [CommandAutocompleteSuggestion] = []
        for await update in updates {
            final = update
        }
        XCTAssertTrue(final.contains { $0.replacementText == "git status" })
    }

    func testCompletionServiceDoesNotPublishAfterContextBecomesInvalid() async throws {
        let directory = try makeTemporaryDirectory()
        let context = LocalAutocompleteContext(
            draft: "gi",
            cursorUTF16Offset: 2,
            history: ["git status"],
            currentDirectory: directory,
            executableSearchPath: "",
            shellGeneration: 1
        )
        let service = CompletionService()
        let updates = await service.suggestions(
            for: context,
            zsh: {
                ZshCompletionProtocol.Response(
                    requestID: "request-3",
                    status: .ok,
                    candidates: []
                )
            },
            isValid: { false }
        )

        var received: [[CommandAutocompleteSuggestion]] = []
        for await update in updates {
            received.append(update)
        }
        XCTAssertTrue(received.isEmpty)
    }

    func testValidEmptyCapturedResultDoesNotBecomeLocalHeuristicSuggestions() throws {
        let root = try makeTemporaryDirectory()
        _ = FileManager.default.createFile(
            atPath: root.appendingPathComponent("local-heuristic-match").path,
            contents: Data()
        )
        let autocomplete = CommandAutocomplete(builtInCommands: [])

        // A non-nil empty array is a successful zsh capture. The caller must
        // map it directly; only capture failure (`nil`) may use local fallback.
        let captured: [ZshCompletionCandidate] = []
        XCTAssertEqual(autocomplete.capturedSuggestions(captured), [])

        let fallback = autocomplete.suggestions(
            for: "pane-fixture local",
            history: [],
            currentDirectory: root,
            executableSearchPath: ""
        )
        XCTAssertEqual(fallback.map(\.replacementText), ["local-heuristic-match"])
    }

    func testWarmZshRequestFramePreservesBufferCursorAndDeadline() throws {
        let deadline = Date(timeIntervalSince1970: 1_750_000_000.125)
        let request = try XCTUnwrap(
            ZshCompletionProtocol.requestBytes(
                requestID: "g7-r42",
                buffer: "git checkout café",
                cursorCharacterOffset: 17,
                deadline: deadline
            )
        )
        let header = request.prefix(ZshCompletionProtocol.headerByteCount)
        let bodyLength = try XCTUnwrap(
            ZshCompletionProtocol.bodyLength(
                fromHeader: Data(header),
                maximum: ZshCompletionProtocol.maximumRequestBodyBytes
            )
        )
        let body = request.dropFirst(ZshCompletionProtocol.headerByteCount)
        XCTAssertEqual(bodyLength, body.count)

        let fields = body.split(
            separator: UInt8(ascii: ";"),
            maxSplits: 4,
            omittingEmptySubsequences: false
        )
        XCTAssertEqual(fields.count, 5)
        XCTAssertEqual(String(decoding: fields[0], as: UTF8.self), "1")
        XCTAssertEqual(String(decoding: fields[1], as: UTF8.self), "g7-r42")
        XCTAssertEqual(String(decoding: fields[2], as: UTF8.self), "1750000000125")
        XCTAssertEqual(String(decoding: fields[3], as: UTF8.self), "17")
        XCTAssertEqual(
            Data(base64Encoded: Data(fields[4])).map { String(decoding: $0, as: UTF8.self) },
            "git checkout café"
        )
    }

    func testWarmZshResponseFrameDecodesLengthPrefixedCandidate() throws {
        let candidateStream = Data("PZC11:9:--verbose9:Show more0".utf8)
        let body = Data(
            "1;g2-r3;ok;\(candidateStream.base64EncodedString())".utf8
        )
        let response = try XCTUnwrap(
            ZshCompletionProtocol.parseResponseBody(body)
        )

        XCTAssertEqual(response.requestID, "g2-r3")
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(
            response.candidates,
            [
                ZshCompletionProtocol.Candidate(
                    replacementText: "--verbose",
                    detail: "Show more",
                    isDirectory: false
                )
            ]
        )
        XCTAssertNil(
            ZshCompletionProtocol.bodyLength(
                fromHeader: Data("0000000G".utf8),
                maximum: ZshCompletionProtocol.maximumResponseBodyBytes
            )
        )
    }

    func testSlowProviderTimesOutWithoutBlockingUsefulResults() async throws {
        let service = CompletionService()
        let request = makeCompletionRequest(generation: 1)
        let local = FakeCompletionProvider(
            identifier: .local,
            delay: .zero,
            values: [
                CompletionCandidate(
                    displayText: "git status",
                    replacementText: "git status",
                    source: .history,
                    kind: .fullCommand
                )
            ]
        )
        let slowZsh = FakeCompletionProvider(
            identifier: .zsh,
            delay: .milliseconds(100),
            values: []
        )

        let stream = await service.responses(
            for: request,
            providers: [local, slowZsh],
            budgets: [.zsh: .milliseconds(5)]
        )
        var responses: [CompletionResponse] = []
        for await response in stream { responses.append(response) }

        XCTAssertTrue(responses.contains {
            $0.candidates.contains { $0.candidate.replacementText == "git status" }
        })
        XCTAssertTrue(responses.last?.diagnostics.contains {
            $0.provider == .zsh && $0.timedOut
        } == true)
    }

    func testStagedProvidersNeverPublishDuplicateRowsAndKeepStableIdentity() async throws {
        let service = CompletionService()
        let request = makeCompletionRequest(
            generation: 1,
            draft: "git st",
            tokenRange: NSRange(location: 4, length: 2)
        )
        var historyEvidence = CompletionEvidence()
        historyEvidence.projectFrequency = 4
        var zshEvidence = CompletionEvidence()
        zshEvidence.acceptanceCount = 3
        let stream = await service.responses(
            for: request,
            providers: [
                FakeCompletionProvider(
                    identifier: .history,
                    delay: .zero,
                    values: [
                        CompletionCandidate(
                            displayText: "git status",
                            replacementText: "git status",
                            replacementRange: NSRange(location: 0, length: 6),
                            source: .history,
                            kind: .fullCommand,
                            evidence: historyEvidence
                        )
                    ]
                ),
                FakeCompletionProvider(
                    identifier: .zsh,
                    delay: .milliseconds(20),
                    values: [
                        CompletionCandidate(
                            displayText: "status",
                            replacementText: "status",
                            replacementRange: NSRange(location: 4, length: 2),
                            source: .zsh,
                            kind: .argument,
                            evidence: zshEvidence
                        )
                    ]
                )
            ]
        )

        var responses: [CompletionResponse] = []
        for await response in stream { responses.append(response) }

        XCTAssertGreaterThanOrEqual(responses.count, 2)
        for response in responses {
            XCTAssertEqual(Set(response.candidates.map(\.id)).count, response.candidates.count)
            XCTAssertEqual(response.candidates.count, 1)
            XCTAssertEqual(response.candidates[0].id, "typedCompletion|false|git status")
        }
        let final = try XCTUnwrap(responses.last?.candidates.first?.candidate)
        XCTAssertEqual(final.source, .zsh)
        XCTAssertEqual(final.supportingSources, [.zsh, .history])
        XCTAssertEqual(final.evidence.projectFrequency, 4)
        XCTAssertEqual(final.evidence.acceptanceCount, 3)
        XCTAssertEqual(final.feedbackIdentityAliases, [
            "argument|false|status",
            "fullCommand|false|git status"
        ])
    }

    func testLateProviderResponseCannotOverwriteNewRequest() async throws {
        let service = CompletionService()
        let first = await service.responses(
            for: makeCompletionRequest(generation: 1),
            providers: [
                FakeCompletionProvider(
                    identifier: .zsh,
                    delay: .milliseconds(80),
                    values: [
                        CompletionCandidate(
                            displayText: "stale",
                            replacementText: "stale",
                            source: .zsh
                        )
                    ]
                )
            ]
        )
        let firstCollector = Task {
            var values: [CompletionResponse] = []
            for await value in first { values.append(value) }
            return values
        }
        try await Task.sleep(for: .milliseconds(5))
        let second = await service.responses(
            for: makeCompletionRequest(generation: 2),
            providers: [
                FakeCompletionProvider(
                    identifier: .local,
                    delay: .zero,
                    values: [
                        CompletionCandidate(
                            displayText: "current",
                            replacementText: "current",
                            source: .history,
                            kind: .fullCommand
                        )
                    ]
                )
            ]
        )
        var current: [CompletionResponse] = []
        for await value in second { current.append(value) }
        let stale = await firstCollector.value

        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(current.last?.candidates.first?.candidate.replacementText, "current")
    }

    func testRecentCommandOutranksOlderCommandUsingTimestamps() {
        let now = Date()
        var recentEvidence = CompletionEvidence()
        recentEvidence.globalRecency = now.timeIntervalSince(now.addingTimeInterval(-60))
        var oldEvidence = CompletionEvidence()
        oldEvidence.globalRecency = now.timeIntervalSince(now.addingTimeInterval(-40 * 24 * 60 * 60))
        let ranked = CompletionRanker().rank([
            CompletionCandidate(
                displayText: "old",
                replacementText: "old",
                source: .history,
                kind: .fullCommand,
                evidence: oldEvidence
            ),
            CompletionCandidate(
                displayText: "recent",
                replacementText: "recent",
                source: .history,
                kind: .fullCommand,
                evidence: recentEvidence
            )
        ])
        XCTAssertEqual(ranked.first?.candidate.replacementText, "recent")
    }

    func testNormalizedCommandFrequencyDoesNotUseSubstringMatching() async throws {
        let directory = try makeTemporaryDirectory()
        let provider = LocalAutocompleteProvider()
        let suggestions = await provider.suggestions(for: LocalAutocompleteContext(
            draft: "te",
            cursorUTF16Offset: 2,
            history: ["pytest", "npm run test", "test"],
            currentDirectory: directory,
            executableSearchPath: "",
            shellGeneration: 1
        ))
        XCTAssertEqual(
            suggestions.first { $0.replacementText == "test" }?.text,
            "test"
        )
        XCTAssertFalse(suggestions.contains {
            $0.replacementText == "pytest" || $0.replacementText == "npm run test"
        })
    }

    func testSecureEligibilityRejectsProviderWork() {
        XCTAssertEqual(
            CompletionEligibility.evaluate(
                interactionState: .commandRunningSecure,
                shellReady: true,
                secureInputActive: true,
                draft: "secret",
                cursorUTF16Offset: 6
            ),
            .secureInput
        )
    }

    func testDifferentReplacementRangesProducingSameResultMerge() {
        let request = makeCompletionRequest(generation: 1, draft: "git st",
            tokenRange: NSRange(location: 4, length: 2))
        let merged = CompletionRanker().deduplicate([
            CompletionCandidate(displayText: "status", replacementText: "status",
                replacementRange: NSRange(location: 4, length: 2), source: .zsh, kind: .argument),
            CompletionCandidate(displayText: "git status", replacementText: "git status",
                replacementRange: NSRange(location: 0, length: 6), source: .history, kind: .fullCommand)
        ], request: request)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .zsh)
        XCTAssertEqual(merged[0].replacementRange, NSRange(location: 4, length: 2))
        XCTAssertEqual(merged[0].supportingSources, [.zsh, .history])
        XCTAssertEqual(merged[0].id, "typedCompletion|false|git status")
    }

    func testCanonicalIdentityPreservesSemanticDifferences() {
        let request = makeCompletionRequest(generation: 1, draft: "git st",
            tokenRange: NSRange(location: 4, length: 2))
        let values = ["git status", "git Status", "git checkout -- foo", "git checkout foo",
                      "cd folder", "cd folder/", "echo 'foo bar'", "echo foo\\ bar"]
        let candidates = values.map {
            CompletionCandidate(displayText: $0, replacementText: $0,
                replacementRange: NSRange(location: 0, length: 6), source: .history,
                kind: .fullCommand)
        }
        XCTAssertEqual(CompletionRanker().deduplicate(candidates, request: request).count, values.count)
    }

    func testSameReplacementAtDifferentRangesDoesNotMergeWhenResultsDiffer() {
        let request = makeCompletionRequest(generation: 1, draft: "echo foo bar",
            tokenRange: NSRange(location: 9, length: 3))
        let candidates = [
            CompletionCandidate(displayText: "baz", replacementText: "baz",
                replacementRange: NSRange(location: 5, length: 3), source: .history, kind: .argument),
            CompletionCandidate(displayText: "baz", replacementText: "baz",
                replacementRange: NSRange(location: 9, length: 3), source: .zsh, kind: .argument)
        ]
        let merged = CompletionRanker().deduplicate(candidates, request: request)
        XCTAssertEqual(Set(merged.compactMap { $0.resultIdentity(for: request)?.resultingText }),
                       ["echo baz bar", "echo foo baz"])
    }

    func testProjectScriptAndHistoryProducingSameCommandMerge() {
        let request = makeCompletionRequest(generation: 1, draft: "npm r",
            tokenRange: NSRange(location: 4, length: 1))
        var projectEvidence = CompletionEvidence()
        projectEvidence.projectMatch = true
        var historyEvidence = CompletionEvidence()
        historyEvidence.projectFrequency = 6
        let merged = CompletionRanker().deduplicate([
            CompletionCandidate(displayText: "test", replacementText: "npm run test",
                replacementRange: NSRange(location: 0, length: 5), source: .projectScript,
                kind: .script, evidence: projectEvidence),
            CompletionCandidate(displayText: "npm run test", replacementText: "npm run test",
                replacementRange: NSRange(location: 0, length: 5), source: .history,
                kind: .fullCommand, evidence: historyEvidence)
        ], request: request)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .projectScript)
        XCTAssertEqual(merged[0].supportingSources, [.projectScript, .history])
        XCTAssertTrue(merged[0].evidence.projectMatch)
        XCTAssertEqual(merged[0].evidence.projectFrequency, 6)
    }

    func testCanonicalDeduplicationMeetsThousandCandidateLatencyTarget() {
        let request = makeCompletionRequest(generation: 1, draft: "git st",
            tokenRange: NSRange(location: 4, length: 2))
        let candidates = (0..<500).flatMap { index in
            let result = "git status-\(index)"
            return [
                CompletionCandidate(displayText: "status-\(index)", replacementText: "status-\(index)",
                    replacementRange: NSRange(location: 4, length: 2), source: .zsh, kind: .argument),
                CompletionCandidate(displayText: result, replacementText: result,
                    replacementRange: NSRange(location: 0, length: 6), source: .history, kind: .fullCommand)
            ]
        }
        let clock = ContinuousClock()
        let started = clock.now
        let merged = CompletionRanker().deduplicate(candidates, request: request)
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(merged.count, 500)
        XCTAssertLessThan(elapsed, .milliseconds(15))
    }

    func testNextCommandAndDirectoryRemainDistinct() {
        let request = makeCompletionRequest(generation: 1, draft: "",
            tokenRange: NSRange(location: 0, length: 0))
        let candidates = [
            CompletionCandidate(displayText: "Documents", replacementText: "Documents",
                source: .history, kind: .fullCommand),
            CompletionCandidate(displayText: "Documents", replacementText: "Documents",
                source: .transition, kind: .nextCommand),
            CompletionCandidate(displayText: "Documents", replacementText: "Documents",
                source: .fileSystem, kind: .path, isDirectory: true)
        ]
        XCTAssertEqual(CompletionRanker().deduplicate(candidates, request: request).count, 3)
    }

    func testCanonicalIdentityHandlesUnicodeAndRejectsSplitSurrogateRange() {
        let request = makeCompletionRequest(generation: 1, draft: "echo 😀x",
            tokenRange: NSRange(location: 5, length: 3))
        let valid = CompletionCandidate(displayText: "😀y", replacementText: "😀y",
            replacementRange: NSRange(location: 5, length: 3), source: .zsh, kind: .argument)
        let invalid = CompletionCandidate(displayText: "bad", replacementText: "bad",
            replacementRange: NSRange(location: 6, length: 1), source: .zsh, kind: .argument)
        XCTAssertEqual(valid.resultIdentity(for: request)?.resultingText, "echo 😀y")
        XCTAssertNil(invalid.resultIdentity(for: request))
        XCTAssertEqual(CompletionRanker().deduplicate([valid, invalid], request: request).count, 1)
    }

    func testTrailingWhitespaceDoesNotCreateDuplicate() {
        let request = makeCompletionRequest(generation: 1, draft: "git",
            tokenRange: NSRange(location: 0, length: 3))
        let candidates = ["git status", "git status   "].map {
            CompletionCandidate(displayText: $0, replacementText: $0,
                replacementRange: NSRange(location: 0, length: 3), source: .history,
                kind: .fullCommand)
        }
        XCTAssertEqual(CompletionRanker().deduplicate(candidates, request: request).count, 1)
    }

    private func makeCompletionRequest(generation: UInt64, draft: String = "git",
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

    private func makeTemporaryDirectory() throws -> URL {
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

    private func makeExecutable(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}

private struct FakeCompletionProvider: CompletionProvider {
    let identifier: CompletionProviderID
    let delay: Duration
    let values: [CompletionCandidate]

    func candidates(for request: CompletionRequest) async throws -> [CompletionCandidate] {
        if delay != .zero { try await Task.sleep(for: delay) }
        return values
    }
}

private actor AsyncCounter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
