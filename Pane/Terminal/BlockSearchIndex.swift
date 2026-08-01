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

    private var documents: [Document] = []
    private var generation: UInt64 = 0

    @discardableResult
    func replace(blocks: [CommandBlock]) -> UInt64 {
        generation &+= 1
        documents = blocks.map { block in
            Document(
                id: block.id,
                command: Self.normalize(block.command),
                output: Self.normalize(block.output),
                directory: Self.normalize(block.workingDirectory),
                status: Self.normalize(block.statusText)
            )
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
            ids = documents.map(\.id)
        } else {
            ids = documents.compactMap { document in
                document.contains(needle, filter: query.filter) ? document.id : nil
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
