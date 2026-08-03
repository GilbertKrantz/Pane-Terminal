import Foundation

enum PanePerformanceThresholds {
    static let typicalTabSwitchMilliseconds = 50.0
    static let typicalBlockPublicationMilliseconds = 16.0
    static let normalSearchUpdateMilliseconds = 50.0
    static let canonicalCompletionDeduplicationUpperBound: Duration = .milliseconds(30)
    static let autocompleteDebounce: Duration = .milliseconds(110)
    static let searchDebounce: Duration = .milliseconds(125)
    static let selectedForegroundPoll: Duration = .milliseconds(250)
    static let backgroundForegroundPoll: Duration = .seconds(2)
    static let backgroundPresentationCoalescing: Duration = .milliseconds(100)

    static let projectDefinitionTTL: TimeInterval = 300
    static let selectedGitTTL: TimeInterval = 10
    static let inactiveGitTTL: TimeInterval = 45

    static let resourceConvergenceTimeout: Duration = .seconds(5)
    static let maximumDescriptorResidualFloor = 4
    static let maximumDescriptorResidualFraction = 0.05
    static let maximumMemoryResidualFraction = 0.15
}
