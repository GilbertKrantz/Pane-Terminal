import Foundation

enum FixtureLocator {
    static func paneFixture(
        testCase: AnyClass,
        sourceFile: StaticString = #filePath
    ) throws -> URL {
#if SWIFT_PACKAGE
        if let bundled = Bundle.module.url(
            forResource: "pane-fixture",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) {
            return bundled
        }
#else
        if let bundled = Bundle(for: testCase).url(
            forResource: "pane-fixture",
            withExtension: nil
        ) {
            return bundled
        }
#endif
        let sourceURL = URL(fileURLWithPath: "\(sourceFile)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pane-fixture")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return sourceURL
    }
}
