#if DEBUG

    import XCTest

    @testable import MailVerdictKit

    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    /// Serves requests from the fixture route table and records every one, so a test can wait on
    /// the requests a page actually made rather than on a delay.
    final class ReaderFixtureRecorder: URLProtocol {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var _requests: [String] = []

        static var requests: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _requests
        }

        static func reset() {
            lock.lock()
            defer { lock.unlock() }
            _requests = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            Self.lock.lock()
            Self._requests.append("\(method) \(path)")
            Self.lock.unlock()
            let match = MVFixtureURLProtocol.route(method: method, path: path)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: match.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: match.body())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// The reader's fixture pages must be served entirely by its own fixture routes. A missing
    /// route does not fail a page outright — the part it feeds (an invitation card, a folder's
    /// role) is simply absent — so the screenshot sweep would show a page quietly missing a piece.
    @MainActor
    final class ReaderFixtureCoverageTests: XCTestCase {

        override func setUp() async throws {
            MVFixtureURLProtocol.resetToDefaults()
            ReaderFixtureRecorder.reset()
        }

        override func tearDown() async throws {
            MVFixtureURLProtocol.resetToDefaults()
        }

        private func waitUntil(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<250 {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return condition()
        }

        func testEveryFixturePageIsServedWithoutAMiss() async throws {
            ReaderFixtures.install()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReaderFixtureRecorder.self]
            let client = MVApiClient(
                requestFactory: try MVRequestFactory(baseURL: "https://fixture.invalid", authProvider: { .none }),
                urlSession: URLSession(configuration: configuration))
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "reader-fixture-coverage-\(UUID())"))
            var sessions: [ReaderSession] = []

            for (settled, rowId) in ReaderFixtures.rowIds.enumerated() {
                let session = ReaderSession(
                    context: ReaderFixtures.context(opening: rowId), api: client,
                    ledger: makeTestLedger(transport: client), placeResolver: MVMessagePlaceResolver(apiClient: client),
                    theme: .light,
                    canvasStore: MVCanvasPreferenceStore(defaults: defaults),
                    cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
                sessions.append(session)
                session.didSettle(on: rowId)

                let loaded = await waitUntil {
                    session.conversation(for: rowId) != nil
                        && [session.paging.olderId, session.paging.newerId].compactMap { $0 }
                            .allSatisfy { session.conversation(for: $0) != nil }
                }
                XCTAssertTrue(loaded, "page or neighbours never loaded for \(rowId)")

                if let message = session.conversation(for: rowId)?.primary,
                    ConversationDocumentBuilder.hasCalendarAttachment(message)
                {
                    let card = await waitUntil { session.invitationStore(for: rowId)?.model != nil }
                    XCTAssertTrue(card, "invitation card never loaded for \(rowId)")
                }

                // The alerts lookup is the last request the settle rules make.
                let settleRulesRan = await waitUntil {
                    ReaderFixtureRecorder.requests.filter { $0 == "GET /api/alerts" }.count == settled + 1
                }
                XCTAssertTrue(settleRulesRan, "settle rules never finished for \(rowId)")
            }

            XCTAssertTrue(
                ReaderFixtureRecorder.requests.contains(
                    "GET /api/calendar/invitations/\(ReaderFixtures.invitationRowId)"),
                "the invitation card was never requested, so this proves nothing about its routes")
            XCTAssertEqual(MVFixtureURLProtocol.misses, [])
            withExtendedLifetime(sessions) {}
        }
    }

#endif
