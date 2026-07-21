import Foundation
import XCTest
@testable import Pane

final class AlternateScreenTranscriptFilterTests: XCTestCase {
    func testAlternateScreenFramesAreReplacedWithoutMergingNormalContent() {
        var filter = AlternateScreenTranscriptFilter()
        let stream = Data(
            "normal buffer\u{001B}[?1049hframe one\u{001B}[2Jframe two\u{001B}[?1049lrestored buffer".utf8
        )

        let result = filter.consume(stream)

        XCTAssertEqual(
            result,
            Data("normal buffer\r\n[Alternate screen active]\r\nrestored buffer".utf8)
        )
        XCTAssertFalse(filter.isAlternateScreenActive)
    }

    func testAllSupportedPrivateModesToggleAcrossSingleByteChunks() {
        for mode in [47, 1047, 1049] {
            var filter = AlternateScreenTranscriptFilter()
            let stream = Data("before\u{001B}[?\(mode)hhidden\u{001B}[?\(mode)lafter".utf8)
            var result = Data()

            for byte in stream {
                result.append(filter.consume(Data([byte])))
            }
            result.append(filter.flush())

            XCTAssertEqual(
                result,
                Data("before\r\n[Alternate screen active]\r\nafter".utf8),
                "Failed DEC private mode \(mode)"
            )
        }
    }

    func testRepeatedEnterEmitsOnePlaceholderPerInactiveToActiveTransition() {
        var filter = AlternateScreenTranscriptFilter()
        let streamText =
            "\u{001B}[?1049hone\u{001B}[?1049htwo\u{001B}[?1049l" +
            "middle\u{001B}[?47hthree\u{001B}[?47l"
        let stream = Data(streamText.utf8)

        let result = filter.consume(stream)

        XCTAssertEqual(
            result,
            AlternateScreenTranscriptFilter.transitionPlaceholder
                + Data("middle".utf8)
                + AlternateScreenTranscriptFilter.transitionPlaceholder
        )
    }

    func testLifecycleMarkerPassesThroughWhileAlternateScreenIsActive() {
        var filter = AlternateScreenTranscriptFilter()
        let marker = Data("\u{001B}]777;Pane;END;0;/tmp\u{0007}".utf8)
        var stream = Data("prefix\u{001B}[?1049hdiscarded".utf8)
        stream.append(marker)
        stream.append(Data("also discarded\u{001B}[?1049lsuffix".utf8))

        var result = Data()
        for chunk in stream.chunked(maximumCount: 3) {
            result.append(filter.consume(chunk))
        }

        var expected = Data("prefix".utf8)
        expected.append(AlternateScreenTranscriptFilter.transitionPlaceholder)
        expected.append(marker)
        expected.append(Data("suffix".utf8))
        XCTAssertEqual(result, expected)
    }

    func testUnrelatedEscapeSequencesRemainByteForByteIdentical() {
        var filter = AlternateScreenTranscriptFilter()
        let stream = Data(
            "text\u{001B}[31mred\u{001B}[0m\u{001B}]0;title\u{0007}\u{001B}7saved\u{001B}8".utf8
        )

        XCTAssertEqual(filter.consume(stream), stream)
        XCTAssertEqual(filter.flush(), Data())
    }

    func testCombinedPrivateModeSequenceIsRecognized() {
        var filter = AlternateScreenTranscriptFilter()
        let stream = Data(
            "before\u{001B}[?25;1049hhidden\u{001B}[?1049;25lafter".utf8
        )

        XCTAssertEqual(
            filter.consume(stream),
            Data("before\r\n[Alternate screen active]\r\nafter".utf8)
        )
    }

    func testOversizedUnterminatedOSCIsDiscardedAndNormalParsingRecovers() {
        var filter = AlternateScreenTranscriptFilter()
        var oversized = Data("\u{001B}]0;".utf8)
        oversized.append(
            Data(
                repeating: 0x61,
                count: AlternateScreenTranscriptFilter.maximumPendingSequenceBytes
            )
        )

        XCTAssertEqual(filter.consume(oversized), Data())
        XCTAssertEqual(filter.consume(Data("recovered".utf8)), Data("recovered".utf8))
        XCTAssertFalse(filter.isAlternateScreenActive)
    }

    func testOversizedSequenceDoesNotResetAlternateScreenState() {
        var filter = AlternateScreenTranscriptFilter()
        var oversized = Data("\u{001B}]0;".utf8)
        oversized.append(
            Data(
                repeating: 0x61,
                count: AlternateScreenTranscriptFilter.maximumPendingSequenceBytes
            )
        )

        var result = filter.consume(Data("\u{001B}[?1049h".utf8))
        result.append(filter.consume(oversized))
        result.append(filter.consume(Data("hidden\u{001B}[?1049lvisible".utf8)))

        XCTAssertEqual(
            result,
            AlternateScreenTranscriptFilter.transitionPlaceholder + Data("visible".utf8)
        )
        XCTAssertFalse(filter.isAlternateScreenActive)
    }
}

private extension Data {
    func chunked(maximumCount: Int) -> [Data] {
        var chunks: [Data] = []
        var index = startIndex
        while index < endIndex {
            let nextIndex = Swift.min(index + maximumCount, endIndex)
            chunks.append(self[index..<nextIndex])
            index = nextIndex
        }
        return chunks
    }
}
