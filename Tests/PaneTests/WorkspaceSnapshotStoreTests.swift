import Foundation
import XCTest
@testable import Pane

final class WorkspaceSnapshotStoreTests: XCTestCase {
    func testAtomicSaveBoundsDraftAndRestoresSnapshot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.json")
        let store = WorkspaceSnapshotStore(snapshotURL: url)
        let tab = metadata(
            draft: String(repeating: "界", count: 40_000)
        )

        try await store.save(snapshot(tabs: [tab], selected: tab.id))
        let loaded = await store.load()
        let restored = try XCTUnwrap(loaded)

        XCTAssertEqual(restored.orderedTabs.count, 1)
        XCTAssertEqual(restored.selectedTabID, tab.id)
        XCTAssertLessThanOrEqual(
            restored.orderedTabs[0].safeComposerDraft?.utf8.count ?? 0,
            WorkspaceSnapshotStore.maximumDraftBytesPerTab
        )
        let diagnostic = await store.diagnostic()
        XCTAssertEqual(diagnostic.status, .ready)
    }

    func testCorruptPrimaryFallsBackToLastKnownGoodBackup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.json")
        let store = WorkspaceSnapshotStore(snapshotURL: url)
        let first = metadata(title: "First")
        let second = metadata(title: "Second")
        try await store.save(snapshot(tabs: [first], selected: first.id))
        try await store.save(snapshot(tabs: [second], selected: second.id))
        try Data("{\"schemaVersion\":1".utf8).write(to: url)

        let loaded = await store.load()
        let restored = try XCTUnwrap(loaded)
        let diagnostic = await store.diagnostic()

        XCTAssertEqual(restored.orderedTabs.map(\.id), [first.id])
        XCTAssertEqual(diagnostic.status, .recovered)
        XCTAssertEqual(diagnostic.failureCategory, .corruption)
        XCTAssertNotNil(diagnostic.recoveryFileName)
    }

    func testMixedSnapshotDropsMalformedEntryAndRepairsSelection() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.json")
        let valid = metadata(title: "Valid")
        let encoded = try JSONEncoder().encode(
            snapshot(tabs: [valid], selected: UUID())
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var tabs = try XCTUnwrap(object["orderedTabs"] as? [[String: Any]])
        tabs.append(["id": "not-a-uuid", "workingDirectoryPath": 42])
        object["orderedTabs"] = tabs
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let store = WorkspaceSnapshotStore(snapshotURL: url)

        let loaded = await store.load()
        let restored = try XCTUnwrap(loaded)

        XCTAssertEqual(restored.orderedTabs.map(\.id), [valid.id])
        XCTAssertEqual(restored.selectedTabID, valid.id)
    }

    func testFaultBeforeReplacementPreservesOnlyValidSnapshot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.json")
        let first = metadata(title: "Stable")
        let replacement = metadata(title: "Interrupted")
        let healthyStore = WorkspaceSnapshotStore(snapshotURL: url)
        try await healthyStore.save(snapshot(tabs: [first], selected: first.id))
        let faultingStore = WorkspaceSnapshotStore(
            snapshotURL: url,
            faultInjector: { checkpoint in
                if checkpoint == .beforeReplacement {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        )

        do {
            try await faultingStore.save(
                snapshot(tabs: [replacement], selected: replacement.id)
            )
            XCTFail("Expected injected persistence fault")
        } catch {
            // The original destination must remain decodable.
        }
        let loaded = await healthyStore.load()
        let restored = try XCTUnwrap(loaded)

        XCTAssertEqual(restored.orderedTabs.map(\.id), [first.id])
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).contains { $0.pathExtension == "tmp" }
        )
    }

    func testSaveBoundsTabsAndDraftWithoutSplittingGraphemeClusters() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.json")
        let store = WorkspaceSnapshotStore(snapshotURL: url)
        let grapheme: Character = "👩🏽‍💻"
        let largeDraft = String(repeating: String(grapheme), count: 10_000)
        let tabs = (0..<40).map { index in
            metadata(
                title: "Tab \(index)",
                draft: index == 0 ? largeDraft : nil,
                order: index
            )
        }

        try await store.save(snapshot(tabs: tabs, selected: tabs[0].id))
        let loaded = await store.load()
        let restored = try XCTUnwrap(loaded)
        let draft = try XCTUnwrap(restored.orderedTabs[0].safeComposerDraft)

        XCTAssertEqual(
            restored.orderedTabs.count,
            WorkspaceSnapshotStore.maximumTabCount
        )
        XCTAssertEqual(restored.selectedTabID, tabs[0].id)
        XCTAssertLessThanOrEqual(
            draft.utf8.count,
            WorkspaceSnapshotStore.maximumDraftBytesPerTab
        )
        XCTAssertTrue(draft.allSatisfy { $0 == grapheme })
    }

    func testUnsupportedSchemaIsQuarantinedWithoutCrashLoop() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(TerminalWorkspaceSnapshot(
            schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion + 1,
            selectedTabID: nil,
            orderedTabs: [],
            savedAt: Date()
        )).write(to: url)
        let store = WorkspaceSnapshotStore(snapshotURL: url)

        let restored = await store.load()
        let diagnostic = await store.diagnostic()

        XCTAssertNil(restored)
        XCTAssertEqual(diagnostic.failureCategory, .unsupportedSchemaVersion)
        XCTAssertNotNil(diagnostic.recoveryFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Pane-WorkspaceStore-\(UUID().uuidString)")
    }

    private func metadata(
        title: String = "Tab",
        draft: String? = nil,
        order: Int = 0
    ) -> TerminalTabRestorationMetadata {
        TerminalTabRestorationMetadata(
            id: UUID(),
            order: order,
            title: title,
            titleSource: .custom,
            workingDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            shellConfigurationID: nil,
            mode: .blocks,
            safeComposerDraft: draft,
            createdAt: Date(),
            lastSelectedAt: Date(),
            hadActiveWork: false
        )
    }

    private func snapshot(
        tabs: [TerminalTabRestorationMetadata],
        selected: UUID?
    ) -> TerminalWorkspaceSnapshot {
        TerminalWorkspaceSnapshot(
            schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion,
            selectedTabID: selected,
            orderedTabs: tabs,
            savedAt: Date()
        )
    }
}
