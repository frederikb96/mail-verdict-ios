import Foundation
import XCTest

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import MailVerdictKit

/// Drives raw SSE bytes — not hand-written lines — through `MVHttpByteStream`,
/// `MVLineSplitter` and `MVSseEventAccumulator`, via the same `URLProtocol` stub the REST client
/// tests use.
///
/// This is the test that would catch a regression back to `bytes(for:)`/`AsyncLineSequence`:
/// `.lines` silently drops blank lines, so the accumulator never sees its record terminator and
/// no event ever decodes — invisible to `MVSseEventAccumulatorTests`, which hand-feeds lines with
/// the blank ones already present and so never exercises the line *source* at all.
final class MVHttpByteStreamTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://stub.example.com/api/events")!)
    }

    /// `URLSession` never calls `didReceive data:` before `didReceive response:` — `.connected`
    /// rides that same guarantee. A regression here would let a caller start counting "have I
    /// heard from the server yet" before the response actually arrived.
    func testConnectedArrivesBeforeAnyChunk() async throws {
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data("hello".utf8))
        let byteStream = MVHttpByteStream()

        var events: [MVHttpByteStream.Event] = []
        for try await event in byteStream.start(
            request: makeRequest(), configuration: MVStubURLProtocol.makeConfiguration())
        {
            events.append(event)
        }

        XCTAssertEqual(events, [.connected, .chunk(Data("hello".utf8))])
    }

    /// A non-2xx must end the stream as an error, never surface the error body as if it were
    /// stream content.
    func testNon2xxStatusEndsTheStreamWithoutDeliveringAnyChunk() async {
        MVStubURLProtocol.stub = .init(statusCode: 404, headers: [:], body: Data("not found".utf8))
        let byteStream = MVHttpByteStream()

        var caughtStatus: Int?
        var sawChunk = false
        do {
            for try await event in byteStream.start(
                request: makeRequest(), configuration: MVStubURLProtocol.makeConfiguration())
            {
                if case .chunk = event { sawChunk = true }
            }
            XCTFail("expected StreamError.unexpectedStatus")
        } catch let MVHttpByteStream.StreamError.unexpectedStatus(status) {
            caughtStatus = status
        } catch {
            XCTFail("unexpected error type: \(error)")
        }

        XCTAssertEqual(caughtStatus, 404)
        XCTAssertFalse(sawChunk, "a rejected response must never surface its body as stream content")
    }

    /// Real SSE framing (`\r\n\r\n`), delivered across three chunks whose boundaries land in the
    /// middle of both a line and a `\r\n` terminator itself — decoded all the way through to
    /// records, id field included.
    func testRawSseBytesAcrossChunkBoundariesDecodeToBothEvents() async throws {
        let raw =
            "id: a-1\r\nevent: verdict_issued\r\ndata: {\"mail_id\":\"1\"}\r\n\r\n"
            + "id: a-2\r\nevent: resync\r\ndata: {}\r\n\r\n"
        let bytes = Array(raw.utf8)
        // First cut lands right after the `\r` of the first line — splitting the terminator
        // itself across chunk 1 and chunk 2.
        let cut1 = "id: a-1\r".utf8.count
        // Second cut lands mid-word inside the second event's name.
        let cut2 = cut1 + "\nevent: verdict_issued\r\ndata: {\"mail_id\":\"1\"}\r\n\r\nid: a-2\r\nevent: res".utf8.count

        MVStubURLProtocol.stub = .init(
            statusCode: 200,
            headers: [:],
            body: Data(bytes),
            bodyChunks: [
                Data(bytes[0..<cut1]),
                Data(bytes[cut1..<cut2]),
                Data(bytes[cut2...]),
            ]
        )

        let byteStream = MVHttpByteStream()
        var splitter = MVLineSplitter()
        var accumulator = MVSseEventAccumulator()
        var decoded: [MVSseRecord] = []

        for try await event in byteStream.start(
            request: makeRequest(), configuration: MVStubURLProtocol.makeConfiguration())
        {
            guard case .chunk(let data) = event else { continue }
            for line in splitter.ingest(data) {
                if let record = accumulator.ingest(line: line) { decoded.append(record) }
            }
        }

        XCTAssertEqual(decoded.map(\.id), ["a-1", "a-2"])
        XCTAssertEqual(decoded.map(\.name), ["verdict_issued", "resync"])
        XCTAssertEqual(decoded.map(\.data), [#"{"mail_id":"1"}"#, "{}"])
    }
}
