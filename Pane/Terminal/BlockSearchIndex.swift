import Foundation

struct IndexedBlockSearchResult: Equatable, Sendable {
    let generation: UInt64
    let query: BlockSearchQuery
    let blockIDs: [UUID]
}

/// A session owns one index. Index construction, normalization, and filtering
/// run on this actor rather than invalidating the main SwiftUI object for every
/// keystroke. A later query invalidates every older debounced result.
actor BlockSearchIndex {
    private struct Document: Sendable {
        let id: UUID
        let command: String
        let output: String
        let directory: String
        let status: String
        let source: Fields

        func contains(_ needle: String, filter: BlockSearchFilter) -> Bool {
            switch filter {
            case .all:
                return command.contains(needle)
                    || output.contains(needle)
                    || directory.contains(needle)
                    || status.contains(needle)
            case .commands:
                return command.contains(needle)
            case .output:
                return output.contains(needle)
            case .directories:
                return directory.contains(needle)
            case .status:
                return status.contains(needle)
            }
        }
    }

    private struct Fields: Equatable, Sendable {
        let command: String
        let output: String
        let directory: String
        let status: String
    }

    private var documents: [UUID: Document] = [:]
    private var orderedIDs: [UUID] = []
    private(set) var normalizedDocumentCount = 0
    private var generation: UInt64 = 0

    @discardableResult
    func replace(blocks: [CommandBlock]) -> UInt64 {
        guard !Task.isCancelled else { return generation }
        var updated = documents
        var changed = false
        var normalizedCount = 0
        let ids = blocks.map(\.id)
        for (offset, block) in blocks.enumerated() {
            if offset.isMultiple(of: 64), Task.isCancelled { return generation }
            let fields = Fields(command: block.command, output: block.output,
                                directory: block.workingDirectory, status: block.statusText)
            guard updated[block.id]?.source != fields else { continue }
            changed = true
            normalizedCount += 1
            updated[block.id] = Document(
                id: block.id,
                command: Self.normalize(block.command),
                output: Self.normalize(block.output),
                directory: Self.normalize(block.workingDirectory),
                status: Self.normalize(block.statusText),
                source: fields
            )
        }
        guard !Task.isCancelled else { return generation }
        if ids != orderedIDs {
            let retained = Set(ids)
            updated = updated.filter { retained.contains($0.key) }
            changed = true
        }
        if changed {
            generation &+= 1
            documents = updated
            orderedIDs = ids
            normalizedDocumentCount += normalizedCount
        }
        return generation
    }

    @discardableResult
    func cancelPendingSearches() -> UInt64 {
        generation &+= 1
        return generation
    }

    func search(
        _ query: BlockSearchQuery,
        debounce: Duration = .milliseconds(125)
    ) async -> IndexedBlockSearchResult? {
        generation &+= 1
        let requestGeneration = generation

        do {
            if debounce > .zero {
                try await Task.sleep(for: debounce)
            }
            try Task.checkCancellation()
        } catch {
            return nil
        }

        guard requestGeneration == generation else { return nil }
        let needle = Self.normalize(
            query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let ids: [UUID]
        if needle.isEmpty {
            ids = orderedIDs
        } else {
            ids = orderedIDs.compactMap { id in
                guard let document = documents[id] else { return nil }
                return document.contains(needle, filter: query.filter) ? document.id : nil
            }
        }
        guard requestGeneration == generation else { return nil }
        return IndexedBlockSearchResult(
            generation: requestGeneration,
            query: query,
            blockIDs: ids
        )
    }

    func currentGeneration() -> UInt64 {
        generation
    }

    private nonisolated static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
