import Foundation
import XCTest

@testable import Push

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Answers every request with one canned response and remembers the request, so the relay client
/// is exercised through a real `URLSession` rather than around it.
final class RelayStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var captured: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured = request
        Self.capturedBody = request.httpBody ?? request.httpBodyStream.map(Self.drain)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class PushRelayClientTests: XCTestCase {

    private let client = PushRelayClient(
        baseURL: URL(string: "https://relay.example")!, session: RelayStubURLProtocol.session())

    func testRegistersTheTokenAndReadsTheRelaysOwnResponseShape() async throws {
        RelayStubURLProtocol.status = 200
        // Exactly what the relay's Go handler writes: RFC 3339 in UTC, no fractional seconds.
        RelayStubURLProtocol.body = Data(
            #"{"ticket":"AQ-sealed","ticket_id":"0123456789abcdef","expires_at":"2026-12-11T10:00:00Z"}"#.utf8)

        let ticket = try await client.register(apnsToken: "a1b2c3d4")

        XCTAssertEqual(RelayStubURLProtocol.captured?.url?.absoluteString, "https://relay.example/v1/register")
        let sent = try JSONDecoder().decode([String: String].self, from: RelayStubURLProtocol.capturedBody ?? Data())
        XCTAssertEqual(sent, ["apns_token": "a1b2c3d4"])
        XCTAssertEqual(ticket.ticket, "AQ-sealed")
        XCTAssertEqual(ticket.expiresAt, Date(timeIntervalSince1970: 1_796_983_200))
    }

    func testARateLimitIsReportedAsSuchRatherThanAsAFailure() async {
        RelayStubURLProtocol.status = 429
        RelayStubURLProtocol.body = Data(#"{"retry_after_seconds":60}"#.utf8)
        do {
            _ = try await client.register(apnsToken: "a1b2c3d4")
            XCTFail("expected a rate-limit error")
        } catch {
            XCTAssertEqual(error as? PushRelayError, .rateLimited)
        }
    }
}
