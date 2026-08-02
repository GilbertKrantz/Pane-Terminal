import AppKit
import Foundation
import XCTest
@testable import Pane

extension CommandAutocompleteTests {
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

}
