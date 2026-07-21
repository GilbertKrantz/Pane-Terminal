import Foundation
import XCTest
@testable import Pane

final class BlockStreamParserTests: XCTestCase {
    func testStartMarkerDecodesDirectTerminalCommand() {
        var parser = BlockStreamParser()
        let command = "printf 'direct command'"
        let encoded = Data(command.utf8).base64EncodedString()

        XCTAssertEqual(
            parser.consume(Data("\u{001B}]777;Pane;START;\(encoded)\u{0007}".utf8)),
            [.commandStarted(command: command)]
        )
    }

    func testParsesMarkersAcrossChunkBoundariesAndPreservesOutput() {
        var parser = BlockStreamParser()
        let stream = Data("""
        prompt echo\u{001B}]777;Pane;START\u{0007}hello\r\nworld\u{001B}]777;Pane;END;0;/tmp/project\u{0007}prompt
        """.utf8)

        var events: [BlockStreamParser.Event] = []
        for byte in stream {
            events.append(contentsOf: parser.consume(Data([byte])))
        }
        events.append(contentsOf: parser.flush())

        XCTAssertTrue(events.contains(.commandStarted(command: nil)))
        XCTAssertTrue(events.contains(.commandFinished(exitCode: 0, workingDirectory: "/tmp/project")))

        let output = events.compactMap { event -> Data? in
            if case .output(let data) = event { return data }
            return nil
        }.reduce(into: Data()) { $0.append($1) }

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "prompt echohello\r\nworldprompt")
    }

    func testMalformedMarkerIsConsumedWithoutCreatingLifecycleEvent() {
        var parser = BlockStreamParser()
        let events = parser.consume(Data("\u{001B}]777;Pane;UNKNOWN\u{0007}".utf8))

        XCTAssertTrue(events.isEmpty)
    }

    func testOrdinaryShortOutputIsEmittedImmediately() {
        var parser = BlockStreamParser()

        XCTAssertEqual(
            parser.consume(Data("working...".utf8)),
            [.output(Data("working...".utf8))]
        )
    }

    func testOnlyAPossiblePartialMarkerIsRetainedAcrossChunks() {
        var parser = BlockStreamParser()
        let first = Data("visible\u{001B}]777;Pa".utf8)

        XCTAssertEqual(
            parser.consume(first),
            [.output(Data("visible".utf8))]
        )
        XCTAssertEqual(
            parser.consume(Data("ne;START\u{0007}".utf8)),
            [.commandStarted(command: nil)]
        )
    }

    func testOversizedUnterminatedMarkerIsDiscardedAndParserRecovers() {
        var parser = BlockStreamParser()
        var oversized = Data("\u{001B}]777;Pane;".utf8)
        oversized.append(
            Data(repeating: 0x61, count: BlockStreamParser.maximumBufferedMarkerBytes)
        )

        XCTAssertEqual(parser.consume(oversized), [])
        XCTAssertEqual(
            parser.consume(Data("visible\u{001B}]777;Pane;START\u{0007}".utf8)),
            [.output(Data("visible".utf8)), .commandStarted(command: nil)]
        )
    }

    func testOversizedTerminatedMarkerDoesNotHideFollowingValidMarker() {
        var parser = BlockStreamParser()
        var stream = Data("\u{001B}]777;Pane;".utf8)
        stream.append(
            Data(repeating: 0x61, count: BlockStreamParser.maximumBufferedMarkerBytes)
        )
        stream.append(0x07)
        stream.append(Data("after\u{001B}]777;Pane;START\u{0007}".utf8))

        XCTAssertEqual(
            parser.consume(stream),
            [.output(Data("after".utf8)), .commandStarted(command: nil)]
        )
    }
}
