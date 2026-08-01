import Foundation
import XCTest
@testable import Pane

@MainActor
final class PaneSoakRunnerTests: XCTestCase {
    func testPresetsDescribeCommonTwoAndEightHourRuns() {
        XCTAssertEqual(
            PaneSoakPreset.twoHours.durationSeconds,
            2 * 60 * 60
        )
        XCTAssertEqual(
            PaneSoakPreset.eightHours.durationSeconds,
            8 * 60 * 60
        )
    }

    func testPaneBackedSoakWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PANE_RUN_PANE_SOAK"] == "1" else {
            throw XCTSkip(
                "Run through Scripts/P2/run-soak.sh for Pane-backed soak evidence"
            )
        }

        let duration = try positiveTimeInterval(
            environment["PANE_SOAK_DURATION_SECONDS"],
            name: "PANE_SOAK_DURATION_SECONDS"
        )
        let interval = try positiveTimeInterval(
            environment["PANE_SOAK_INTERVAL_SECONDS"],
            name: "PANE_SOAK_INTERVAL_SECONDS"
        )
        let artifactURL = try requiredURL(
            environment["PANE_SOAK_ARTIFACT"],
            name: "PANE_SOAK_ARTIFACT"
        )
        let diagnosticsURL = try requiredURL(
            environment["PANE_SOAK_DIAGNOSTICS_DIR"],
            name: "PANE_SOAK_DIAGNOSTICS_DIR"
        )
        let fixtureURL = try FixtureLocator.paneFixture(
            testCase: PaneSoakRunnerTests.self
        )

        let result = try await PaneSoakRunner(
            configuration: PaneSoakConfiguration(
                durationSeconds: duration,
                intervalSeconds: interval,
                artifactURL: artifactURL,
                diagnosticsDirectory: diagnosticsURL
            ),
            fixtureURL: fixtureURL
        ).run()

        XCTAssertEqual(result.baseTabCount, 8)
        XCTAssertEqual(result.backgroundProducerCount, 4)
        XCTAssertEqual(result.interactiveFixtureCount, 2)
        XCTAssertEqual(result.idleShellCount, 2)
        XCTAssertGreaterThanOrEqual(result.sampleCount, 1)
        XCTAssertTrue(result.performedActions.contains("marker"))
        XCTAssertTrue(result.performedActions.contains("tab-switch"))
        XCTAssertTrue(
            result.performedActions.contains("temporary-tab-create-close")
        )
        XCTAssertTrue(result.performedActions.contains("autocomplete"))
        XCTAssertTrue(result.performedActions.contains("resize"))
        XCTAssertTrue(result.cleanupConverged)
        XCTAssertLessThanOrEqual(result.cleanupDuration, 2)
        XCTAssertEqual(result.evidenceMode, "pane-backed-xctest")

        let lines = try String(
            contentsOf: artifactURL,
            encoding: .utf8
        ).split(separator: "\n")
        XCTAssertEqual(lines.count, result.sampleCount)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            let data = Data(line.utf8)
            let sample = try decoder.decode(PaneSoakSample.self, from: data)
            XCTAssertGreaterThanOrEqual(sample.liveSessionCount, 8)
            XCTAssertGreaterThanOrEqual(sample.livePTYCount, 8)

            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            )
            XCTAssertEqual(
                object["evidenceMode"] as? String,
                "pane-backed-xctest"
            )
            XCTAssertEqual(object["automatedPaneBacked"] as? Bool, true)
            XCTAssertEqual(object["visualEvidence"] as? Bool, false)
        }

        let summaryURL = artifactURL.appendingPathExtension(
            "summary.json"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: summaryURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: diagnosticsURL
                    .appendingPathComponent("pane-diagnostics.json").path
            )
        )
    }

    private func positiveTimeInterval(
        _ rawValue: String?,
        name: String
    ) throws -> TimeInterval {
        guard let rawValue,
              let value = TimeInterval(rawValue),
              value > 0 else {
            throw PaneSoakTestConfigurationError(
                "\(name) must be a positive number"
            )
        }
        return value
    }

    private func requiredURL(
        _ rawValue: String?,
        name: String
    ) throws -> URL {
        guard let rawValue, rawValue.hasPrefix("/") else {
            throw PaneSoakTestConfigurationError(
                "\(name) must be an absolute path"
            )
        }
        return URL(fileURLWithPath: rawValue)
    }
}

private struct PaneSoakTestConfigurationError:
    Error,
    CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
