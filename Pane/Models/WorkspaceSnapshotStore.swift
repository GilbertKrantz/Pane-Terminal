import Darwin
import Foundation

enum WorkspaceSnapshotFaultCheckpoint: String, Sendable {
    case beforeTemporaryWrite
    case afterTemporaryWrite
    case afterSynchronization
    case beforeReplacement
    case afterReplacement
}

enum WorkspaceSnapshotStoreError: Error, Equatable {
    case snapshotTooLarge(Int)
    case unsupportedSchemaVersion(Int)
    case malformedSnapshot
}

/// Serializes bounded workspace metadata independently of the main actor.
/// Only safe metadata is accepted; live PTYs, terminal buffers, secure input,
/// and process state are deliberately not part of this store.
actor WorkspaceSnapshotStore {
    static let maximumTabCount = 32
    static let maximumSnapshotBytes = 1 * 1_024 * 1_024
    static let maximumDraftBytesPerTab = 64 * 1_024

    nonisolated let snapshotURL: URL
    nonisolated let backupURL: URL

    private let fileManager: FileManager
    private let faultInjector: (@Sendable (WorkspaceSnapshotFaultCheckpoint) throws -> Void)?
    private var persistenceStatus: PersistenceDiagnostic

    init(
        snapshotURL: URL,
        fileManager: FileManager = .default,
        faultInjector: (@Sendable (WorkspaceSnapshotFaultCheckpoint) throws -> Void)? = nil
    ) {
        self.snapshotURL = snapshotURL
        self.backupURL = snapshotURL
            .deletingPathExtension()
            .appendingPathExtension("backup.json")
        self.fileManager = fileManager
        self.faultInjector = faultInjector
        self.persistenceStatus = PersistenceDiagnostic(
            status: .ready,
            failureCategory: nil,
            schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion,
            recoveryFileName: nil,
            message: nil
        )
    }

    func diagnostic() -> PersistenceDiagnostic {
        persistenceStatus
    }

    func load() -> TerminalWorkspaceSnapshot? {
        cleanupOrphanTemporaryFiles()
        let primaryExists = fileManager.fileExists(atPath: snapshotURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)
        guard primaryExists || backupExists else {
            persistenceStatus = readyDiagnostic()
            return nil
        }

        do {
            let snapshot = try decodeSnapshot(at: snapshotURL)
            persistenceStatus = readyDiagnostic()
            return snapshot
        } catch {
            let category = failureCategory(for: error)
            let shouldQuarantine = category == .corruption
                || category == .unsupportedSchemaVersion
            let recoveryName = primaryExists && shouldQuarantine
                ? quarantine(snapshotURL)?.lastPathComponent
                : nil

            do {
                let backup = try decodeSnapshot(at: backupURL)
                persistenceStatus = PersistenceDiagnostic(
                    status: .recovered,
                    failureCategory: primaryExists ? category : nil,
                    schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion,
                    recoveryFileName: recoveryName,
                    message: "Pane restored the last known good workspace snapshot."
                )
                return backup
            } catch {
                persistenceStatus = PersistenceDiagnostic(
                    status: .memoryOnly,
                    failureCategory: primaryExists ? category : failureCategory(for: error),
                    schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion,
                    recoveryFileName: recoveryName,
                    message: "Workspace metadata could not be restored; Pane created a fresh tab."
                )
                return nil
            }
        }
    }

    func save(_ proposedSnapshot: TerminalWorkspaceSnapshot) throws {
        cleanupOrphanTemporaryFiles()
        let snapshot = boundedSnapshot(proposedSnapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumSnapshotBytes else {
            let error = WorkspaceSnapshotStoreError.snapshotTooLarge(data.count)
            recordWriteFailure(error)
            throw error
        }

        let directory = snapshotURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let temporaryURL = directory.appendingPathComponent(
            ".\(snapshotURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        do {
            try faultInjector?(.beforeTemporaryWrite)
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try faultInjector?(.afterTemporaryWrite)
            try synchronizeFile(at: temporaryURL)
            try faultInjector?(.afterSynchronization)

            if fileManager.fileExists(atPath: snapshotURL.path) {
                try preserveBackup()
            }

            try faultInjector?(.beforeReplacement)
            if fileManager.fileExists(atPath: snapshotURL.path) {
                _ = try fileManager.replaceItemAt(
                    snapshotURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: snapshotURL)
            }
            try synchronizeDirectory(at: directory)
            try faultInjector?(.afterReplacement)
            persistenceStatus = readyDiagnostic()
        } catch {
            recordWriteFailure(error)
            throw error
        }
    }

    private func decodeSnapshot(at url: URL) throws -> TerminalWorkspaceSnapshot {
        guard fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty, data.count <= Self.maximumSnapshotBytes else {
            throw WorkspaceSnapshotStoreError.malformedSnapshot
        }
        let decoded = try JSONDecoder().decode(LossyWorkspaceSnapshot.self, from: data)
        guard decoded.schemaVersion == TerminalWorkspaceSnapshot.currentSchemaVersion else {
            throw WorkspaceSnapshotStoreError.unsupportedSchemaVersion(decoded.schemaVersion)
        }

        let now = Date()
        var seen: Set<UUID> = []
        var tabs: [TerminalTabRestorationMetadata] = []
        for candidate in decoded.orderedTabs where tabs.count < Self.maximumTabCount {
            guard seen.insert(candidate.id).inserted else { continue }
            let createdAt = Self.repairedDate(candidate.createdAt, fallback: decoded.savedAt, now: now)
            let lastSelectedAt = max(
                createdAt,
                Self.repairedDate(candidate.lastSelectedAt, fallback: createdAt, now: now)
            )
            tabs.append(TerminalTabRestorationMetadata(
                id: candidate.id,
                order: tabs.count,
                title: Self.sanitizeTitle(candidate.title),
                titleSource: candidate.titleSource,
                workingDirectoryPath: candidate.workingDirectoryPath,
                shellConfigurationID: candidate.shellConfigurationID,
                mode: candidate.mode,
                safeComposerDraft: Self.utf8Prefix(
                    candidate.safeComposerDraft,
                    maximumBytes: Self.maximumDraftBytesPerTab
                ),
                createdAt: createdAt,
                lastSelectedAt: lastSelectedAt,
                hadActiveWork: candidate.hadActiveWork
            ))
        }

        let selectedID = decoded.selectedTabID.flatMap { selected in
            tabs.contains(where: { $0.id == selected }) ? selected : nil
        } ?? tabs.first?.id
        return TerminalWorkspaceSnapshot(
            schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion,
            selectedTabID: selectedID,
            orderedTabs: tabs,
            savedAt: Self.repairedDate(decoded.savedAt, fallback: now, now: now)
        )
    }

    private func boundedSnapshot(
        _ snapshot: TerminalWorkspaceSnapshot
    ) -> TerminalWorkspaceSnapshot {
        var seen: Set<UUID> = []
        let tabs = snapshot.orderedTabs
            .sorted {
                if $0.order == $1.order {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.order < $1.order
            }
            .filter { seen.insert($0.id).inserted }
            .prefix(Self.maximumTabCount)
            .enumerated()
            .map { index, tab in
                TerminalTabRestorationMetadata(
                    id: tab.id,
                    order: index,
                    title: Self.sanitizeTitle(tab.title),
                    titleSource: tab.titleSource,
                    workingDirectoryPath: tab.workingDirectoryPath,
                    shellConfigurationID: tab.shellConfigurationID,
                    mode: tab.mode,
                    safeComposerDraft: Self.utf8Prefix(
                        tab.safeComposerDraft,
                        maximumBytes: Self.maximumDraftBytesPerTab
                    ),
                    createdAt: tab.createdAt,
                    lastSelectedAt: tab.lastSelectedAt,
                    hadActiveWork: tab.hadActiveWork
                )
            }
        let selectedID = snapshot.selectedTabID.flatMap { selected in
            tabs.contains(where: { $0.id == selected }) ? selected : nil
        } ?? tabs.first?.id
        return TerminalWorkspaceSnapshot(
            schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion,
            selectedTabID: selectedID,
            orderedTabs: tabs,
            savedAt: snapshot.savedAt
        )
    }

    private func preserveBackup() throws {
        let directory = snapshotURL.deletingLastPathComponent()
        let temporaryBackup = directory.appendingPathComponent(
            ".\(backupURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer {
            if fileManager.fileExists(atPath: temporaryBackup.path) {
                try? fileManager.removeItem(at: temporaryBackup)
            }
        }
        try fileManager.copyItem(at: snapshotURL, to: temporaryBackup)
        try synchronizeFile(at: temporaryBackup)
        if fileManager.fileExists(atPath: backupURL.path) {
            _ = try fileManager.replaceItemAt(
                backupURL,
                withItemAt: temporaryBackup,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryBackup, to: backupURL)
        }
    }

    private func cleanupOrphanTemporaryFiles() {
        let directory = snapshotURL.deletingLastPathComponent()
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        let acceptedPrefixes = [
            ".\(snapshotURL.lastPathComponent).",
            ".\(backupURL.lastPathComponent)."
        ]
        for url in urls where
            url.pathExtension == "tmp"
                && acceptedPrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func quarantine(_ url: URL) -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let recovery = url.deletingLastPathComponent().appendingPathComponent(
            "workspace-recovery-\(stamp)-\(UUID().uuidString).json"
        )
        do {
            try fileManager.moveItem(at: url, to: recovery)
            return recovery
        } catch {
            return nil
        }
    }

    private func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func recordWriteFailure(_ error: Error) {
        persistenceStatus = PersistenceDiagnostic(
            status: .memoryOnly,
            failureCategory: failureCategory(for: error),
            schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion,
            recoveryFileName: nil,
            message: "Workspace changes remain live, but the snapshot could not be saved."
        )
    }

    private func readyDiagnostic() -> PersistenceDiagnostic {
        PersistenceDiagnostic(
            status: .ready,
            failureCategory: nil,
            schemaVersion: TerminalWorkspaceSnapshot.currentSchemaVersion,
            recoveryFileName: nil,
            message: nil
        )
    }

    private func failureCategory(
        for error: Error
    ) -> RuntimeStatePersistenceFailureCategory {
        if case WorkspaceSnapshotStoreError.unsupportedSchemaVersion = error {
            return .unsupportedSchemaVersion
        }
        if error is DecodingError
            || error as? WorkspaceSnapshotStoreError == .malformedSnapshot {
            return .corruption
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           (
               cocoa.code == NSFileReadNoPermissionError
                   || cocoa.code == NSFileWriteNoPermissionError
           ) {
            return .permission
        }
        return .io
    }

    private static func repairedDate(
        _ date: Date,
        fallback: Date,
        now: Date
    ) -> Date {
        let time = date.timeIntervalSinceReferenceDate
        guard time.isFinite,
              date <= now.addingTimeInterval(24 * 60 * 60) else {
            return fallback
        }
        return date
    }

    private static func utf8Prefix(
        _ value: String?,
        maximumBytes: Int
    ) -> String? {
        guard let value else { return nil }
        guard value.utf8.count > maximumBytes else { return value }
        let byteLimit = max(0, maximumBytes)
        var retainedBytes = 0
        var end = value.startIndex
        for index in value.indices {
            let next = value.index(after: index)
            let characterBytes = value[index..<next].utf8.count
            guard retainedBytes + characterBytes <= byteLimit else { break }
            retainedBytes += characterBytes
            end = next
        }
        return String(value[..<end])
    }

    private static func sanitizeTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !clean.isEmpty else { return nil }
        return String(clean.prefix(200))
    }
}

private struct LossyWorkspaceSnapshot: Decodable {
    let schemaVersion: Int
    let selectedTabID: UUID?
    let orderedTabs: [TerminalTabRestorationMetadata]
    let savedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, selectedTabID, orderedTabs, savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        selectedTabID = try? container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        savedAt = (try? container.decode(Date.self, forKey: .savedAt)) ?? Date()

        var values: [TerminalTabRestorationMetadata] = []
        var tabs = try container.nestedUnkeyedContainer(forKey: .orderedTabs)
        while !tabs.isAtEnd {
            do {
                values.append(try tabs.decode(TerminalTabRestorationMetadata.self))
            } catch {
                _ = try? tabs.decode(DiscardedJSONValue.self)
            }
        }
        orderedTabs = values
    }
}

private enum DiscardedJSONValue: Decodable {
    case value

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd {
                _ = try? array.decode(DiscardedJSONValue.self)
            }
            self = .value
            return
        }
        if let object = try? decoder.container(
            keyedBy: DiscardedJSONCodingKey.self
        ) {
            for key in object.allKeys {
                _ = try? object.decode(DiscardedJSONValue.self, forKey: key)
            }
            self = .value
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil()
            || (try? single.decode(Bool.self)) != nil
            || (try? single.decode(Double.self)) != nil
            || (try? single.decode(String.self)) != nil {
            self = .value
            return
        }
        throw WorkspaceSnapshotStoreError.malformedSnapshot
    }
}

private struct DiscardedJSONCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
