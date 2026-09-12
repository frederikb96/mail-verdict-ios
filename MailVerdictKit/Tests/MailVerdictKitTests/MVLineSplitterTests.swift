import XCTest
@testable import MailVerdictKit

final class MVLineSplitterTests: XCTestCase {

    /// The one rule `String.split`/`.lines` gets wrong for this purpose: a blank line is the SSE
    /// record terminator, so dropping it silently un-terminates every event.
    func testBlankLinesSurvive() {
        var splitter = MVLineSplitter()
        let lines = splitter.ingest(Data("event: a\ndata: 1\n\nevent: b\ndata: 2\n\n".utf8))
        XCTAssertEqual(lines, ["event: a", "data: 1", "", "event: b", "data: 2", ""])
    }

    /// A `\r` at the very end of a chunk might be the first half of a `\r\n` the next chunk
    /// completes — treating it as a terminator on its own would split one line into two.
    func testLoneTrailingCarriageReturnIsHeldBackAcrossChunks() {
        var splitter = MVLineSplitter()
        XCTAssertEqual(splitter.ingest(Data("data: hello\r".utf8)), [])
        XCTAssertEqual(splitter.ingest(Data("\ndata: next\r\n".utf8)), ["data: hello", "data: next"])
    }

    /// A lone `\r` with no following `\n` in the SAME chunk is still a complete line — only a
    /// `\r` at the chunk boundary is ambiguous.
    func testLoneCarriageReturnWithinOneChunkTerminatesTheLine() {
        var splitter = MVLineSplitter()
        XCTAssertEqual(splitter.ingest(Data("one\rtwo\r\n".utf8)), ["one", "two"])
    }

    func testPartialLineIsBufferedUntilItsTerminatorArrives() {
        var splitter = MVLineSplitter()
        XCTAssertEqual(splitter.ingest(Data("data: par".utf8)), [])
        XCTAssertEqual(splitter.ingest(Data("tial\n".utf8)), ["data: partial"])
    }

    func testFinishFlushesAnUnterminatedTrailingLine() {
        var splitter = MVLineSplitter()
        _ = splitter.ingest(Data("data: complete\n".utf8))
        _ = splitter.ingest(Data("data: no terminator yet".utf8))
        XCTAssertEqual(splitter.finish(), "data: no terminator yet")
        XCTAssertNil(splitter.finish(), "a second call with nothing pending must not repeat the line")
    }
}
