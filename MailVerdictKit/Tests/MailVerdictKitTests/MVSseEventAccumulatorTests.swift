import XCTest
@testable import MailVerdictKit

final class MVSseEventAccumulatorTests: XCTestCase {

    func testCompleteRecordIsEmittedOnTheBlankLine() {
        var accumulator = MVSseEventAccumulator()
        XCTAssertNil(accumulator.ingest(line: "id: a1b2-7"))
        XCTAssertNil(accumulator.ingest(line: "event: verdict_issued"))
        XCTAssertNil(accumulator.ingest(line: #"data: {"mail_id":"1"}"#))
        let record = accumulator.ingest(line: "")
        XCTAssertEqual(record, MVSseRecord(id: "a1b2-7", name: "verdict_issued", data: #"{"mail_id":"1"}"#))
    }

    /// Multiple `data:` lines join with `\n` per the SSE spec, not concatenated bare — a
    /// multi-line JSON payload (pretty-printed, or wrapped) must come back with its line breaks
    /// intact.
    func testMultipleDataLinesJoinWithNewlines() {
        var accumulator = MVSseEventAccumulator()
        _ = accumulator.ingest(line: "event: resync")
        _ = accumulator.ingest(line: "data: line one")
        _ = accumulator.ingest(line: "data: line two")
        let record = accumulator.ingest(line: "")
        XCTAssertEqual(record?.data, "line one\nline two")
    }

    /// An `: keepalive` comment line — sent by the backend on an idle connection so an
    /// intermediary does not time the connection out — carries no event at all and must not be
    /// read as stray data glued onto whatever record is mid-accumulation.
    func testCommentLineIsIgnored() {
        var accumulator = MVSseEventAccumulator()
        _ = accumulator.ingest(line: "event: connected")
        XCTAssertNil(accumulator.ingest(line: ": keepalive"))
        _ = accumulator.ingest(line: "data: {}")
        let record = accumulator.ingest(line: "")
        XCTAssertEqual(record?.data, "{}")
    }

    /// A record with no event name, or no data, is incomplete — matching the original inline
    /// accumulation this type was extracted from, this is discarded rather than emitted with a
    /// placeholder.
    func testIncompleteRecordIsDiscardedNotEmitted() {
        var nameless = MVSseEventAccumulator()
        _ = nameless.ingest(line: "data: orphaned")
        XCTAssertNil(nameless.ingest(line: ""))

        var dataless = MVSseEventAccumulator()
        _ = dataless.ingest(line: "event: empty")
        XCTAssertNil(dataless.ingest(line: ""))
    }

    /// State resets after each record, so a keepalive or a second event right after a first one
    /// does not inherit the previous record's id or name.
    func testStateResetsBetweenRecords() {
        var accumulator = MVSseEventAccumulator()
        _ = accumulator.ingest(line: "id: a1b2-1")
        _ = accumulator.ingest(line: "event: first")
        _ = accumulator.ingest(line: "data: one")
        _ = accumulator.ingest(line: "")

        _ = accumulator.ingest(line: "event: second")
        _ = accumulator.ingest(line: "data: two")
        let second = accumulator.ingest(line: "")
        XCTAssertEqual(second, MVSseRecord(id: nil, name: "second", data: "two"))
    }

    /// Per the SSE spec only ONE leading space after `data:` is part of the framing; the rest of
    /// the line is payload, including any further whitespace.
    func testOnlyOneLeadingSpaceIsStrippedFromDataValue() {
        XCTAssertEqual(MVSseEventAccumulator.sseDataValue(from: "  two spaces"), " two spaces")
        XCTAssertEqual(MVSseEventAccumulator.sseDataValue(from: "no leading space"), "no leading space")
    }
}
