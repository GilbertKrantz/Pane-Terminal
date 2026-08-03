import XCTest
@testable import Pane

final class PanePreferencesStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "PanePreferencesStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testEmptyStoreLoadsAndPersistsDefaults() throws {
        let defaults = defaults()
        let store = PanePreferencesStore(defaults: defaults)
        XCTAssertEqual(try store.load(), .defaults)
        XCTAssertNotNil(defaults.data(forKey: PanePreferencesStore.snapshotKey))
    }

    func testSavesAndReloadsAllCategories() throws {
        let defaults = defaults(); let store = PanePreferencesStore(defaults: defaults)
        var snapshot = PanePreferencesSnapshot.defaults
        snapshot.general.defaultInputMode = .terminal
        snapshot.appearance.mode = .dark
        snapshot.terminal.scrollbackLimit = 50_000
        snapshot.completions.resultLimit = 12
        snapshot.history.maximumRestoredSessions = 9
        try store.save(snapshot)
        XCTAssertEqual(try store.load(), snapshot)
    }

    func testCorruptSnapshotRecoversLegacyHistoryAndWritesValidData() throws {
        let defaults = defaults()
        defaults.set(Data("not-json".utf8), forKey: PanePreferencesStore.snapshotKey)
        defaults.set(false, forKey: "runtimeState.commandHistoryEnabled")
        let store = PanePreferencesStore(defaults: defaults)
        XCTAssertFalse(try store.load().history.commandHistoryEnabled)
        XCTAssertNotNil(store.fallbackDiagnostic)
        XCTAssertNoThrow(try JSONDecoder().decode(PanePreferencesSnapshot.self,
            from: defaults.data(forKey: PanePreferencesStore.snapshotKey)!))
    }

    func testLegacyAggregateMigrationIsIdempotent() throws {
        let defaults = defaults()
        defaults.set(false, forKey: "runtimeState.predictionHistoryEnabled")
        defaults.set(999, forKey: "runtimeState.maximumRestoredCommands")
        let store = PanePreferencesStore(defaults: defaults)
        let first = try store.load(), second = try store.load()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.history.commandHistoryEnabled)
        XCTAssertEqual(first.history.maximumRestoredCommands, 999)
    }

    func testValidationClampsAndReplacesInvalidValues() throws {
        let defaults = defaults(); let store = PanePreferencesStore(defaults: defaults)
        var snapshot = PanePreferencesSnapshot.defaults
        snapshot.appearance.terminalFont.size = 100
        snapshot.completions.resultLimit = 7
        snapshot.terminal.scrollbackLimit = -1
        snapshot.history.maximumRestoredSessions = 99
        try store.save(snapshot)
        let loaded = try store.load()
        XCTAssertEqual(loaded.appearance.terminalFont.size, 24)
        XCTAssertEqual(loaded.completions.resultLimit, 8)
        XCTAssertEqual(loaded.terminal.scrollbackLimit, 10_000)
        XCTAssertEqual(loaded.history.maximumRestoredSessions, 10)
    }

    func testResetOnlyChangesPreferencesDomain() throws {
        let defaults = defaults(); let store = PanePreferencesStore(defaults: defaults)
        defaults.set("history remains", forKey: "test.history")
        var snapshot = PanePreferencesSnapshot.defaults; snapshot.appearance.mode = .dark
        try store.save(snapshot); try store.reset()
        XCTAssertEqual(try store.load(), .defaults)
        XCTAssertEqual(defaults.string(forKey: "test.history"), "history remains")
    }
}
