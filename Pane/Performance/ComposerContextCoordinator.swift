import Foundation

enum ContextRefreshReason: Equatable, Sendable {
    case directoryChanged
    case tabSelected
    case gitCommandCompleted
    case ttlExpired
    case manual
}

/// The single project-context cache coordinator used by both autocomplete and
/// the composer header. Definitions are relatively durable while Git metadata
/// is refreshed more often for the selected session.
actor ComposerContextCoordinator {
    private let provider: ProjectContextProvider
    private let projectDefinitionCache: ProjectDefinitionCache
    private let gitContextCache: GitContextCache
    private let selectedGitTTL: TimeInterval
    private let inactiveGitTTL: TimeInterval
    private let now: @Sendable () -> Date

    init(
        provider: ProjectContextProvider = ProjectContextProvider(),
        projectDefinitionCache: ProjectDefinitionCache = ProjectDefinitionCache(
            ttl: PanePerformanceThresholds.projectDefinitionTTL
        ),
        gitContextCache: GitContextCache = GitContextCache(),
        selectedGitTTL: TimeInterval = PanePerformanceThresholds.selectedGitTTL,
        inactiveGitTTL: TimeInterval = PanePerformanceThresholds.inactiveGitTTL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.projectDefinitionCache = projectDefinitionCache
        self.gitContextCache = gitContextCache
        self.selectedGitTTL = max(1, selectedGitTTL)
        self.inactiveGitTTL = max(self.selectedGitTTL, inactiveGitTTL)
        self.now = now
    }

    func context(
        for directory: URL,
        visibility: SessionVisibilityState,
        reason: ContextRefreshReason
    ) async -> ProjectContext? {
        PaneResourceCounters.increment(.contextRefreshTask)
        defer { PaneResourceCounters.decrement(.contextRefreshTask) }

        if reason == .manual {
            await projectDefinitionCache.invalidate()
            await gitContextCache.invalidate()
        }

        guard !Task.isCancelled,
              let definition = await definition(for: directory) else {
            return nil
        }

        if reason == .gitCommandCompleted {
            await gitContextCache.invalidate(root: definition.root)
        }

        let ttl = visibility == .selected ? selectedGitTTL : inactiveGitTTL
        let git = await gitContextCache.value(
            for: definition.root,
            ttl: ttl,
            now: now()
        ) {
            await self.provider.gitContext(root: definition.root)
        }
        guard !Task.isCancelled else { return nil }
        return Self.merging(definition: definition, git: git)
    }

    func definition(for directory: URL) async -> ProjectContext? {
        await projectDefinitionCache.value(for: directory, now: now()) {
            self.provider.definition(for: directory)
        }
    }

    func invalidateGit(root: URL? = nil) async {
        await gitContextCache.invalidate(root: root)
    }

    func invalidateAll() async {
        await projectDefinitionCache.invalidate()
        await gitContextCache.invalidate()
    }

    private static func merging(
        definition: ProjectContext,
        git: GitContext?
    ) -> ProjectContext {
        ProjectContext(
            root: definition.root,
            identity: definition.identity,
            kind: definition.kind,
            git: git,
            manifests: definition.manifests,
            scripts: definition.scripts,
            detectedLanguages: definition.detectedLanguages,
            discoveredAt: definition.discoveredAt
        )
    }
}
