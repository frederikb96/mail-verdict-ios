import XCTest

@testable import MailVerdictKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A route table of canned responses keyed by method and path, recording every request — the
/// reader session calls several endpoints per page, which a single canned response cannot serve.
final class ReaderRouteStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var _recorded: [String] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes = [:]
        _recorded = []
    }

    static func route(_ method: String, _ path: String, status: Int = 200, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        routes["\(method) \(path)"] = (status, body)
    }

    static func route<T: Encodable>(_ method: String, _ path: String, json value: T) {
        route(method, path, body: (try? JSONEncoder.mvDefault.encode(value)) ?? Data())
    }

    static var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _recorded
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderRouteStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        Self.lock.lock()
        Self._recorded.append(key)
        let match = Self.routes[key] ?? (404, Data(#"{"detail":"no route"}"#.utf8))
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: match.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class ReaderSessionTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    override func setUp() async throws {
        ReaderRouteStub.reset()
    }

    private func message(_ id: UUID, seen: Bool) -> MessageDetail {
        ReaderFixtures.message(
            id: id, from: "Alice <alice@example.org>", to: [], subject: "s", html: "<p>x</p>", text: nil, minutesAgo: 1,
            isSeen: seen)
    }

    private func makeClient() throws -> MVApiClient {
        MVApiClient(
            requestFactory: try MVRequestFactory(baseURL: "https://mail.example", authProvider: { .none }),
            urlSession: ReaderRouteStub.makeSession())
    }

    private func makeSession(
        rows: [UUID], opening: UUID, seen: Bool = false, tracker: MVExplicitUnreadTracker = MVExplicitUnreadTracker(),
        threadCache: MVThreadCache? = nil, referenceCache: MVReferenceCache? = nil
    ) throws -> (ReaderSession, ReaderTestSource) {
        for id in rows {
            ReaderRouteStub.route(
                "GET", "/api/messages/\(id)/thread", json: ThreadResponse(messages: [message(id, seen: seen)]))
        }
        ReaderRouteStub.route("GET", "/api/accounts/\(ReaderFixtures.accountId)/folders", json: [FolderResponse]())
        ReaderRouteStub.route("GET", "/api/contacts/photo-index", json: ContactPhotoIndexResponse(byEmail: [:]))
        ReaderRouteStub.route("GET", "/api/alerts", json: [AlertResponse]())

        let source = ReaderTestSource(rowIds: rows)
        let registry = ReaderSourceRegistry()
        let context = ReaderContext(source: .spamReview, messageId: opening)
        registry.register(source, for: context.source)
        let client = try makeClient()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reader-session-\(UUID())"))
        let session = ReaderSession(
            context: context, api: client, placeResolver: MVMessagePlaceResolver(apiClient: client), theme: .light,
            registry: registry, tracker: tracker,
            canvasStore: MVCanvasPreferenceStore(defaults: defaults),
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            threadCache: threadCache, referenceCache: referenceCache)
        return (session, source)
    }

    /// Waits for the condition the next assertion checks, never a fixed delay.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func actionPath(_ id: UUID) -> String { "POST /api/messages/\(id)/action" }

    func testSettlingMarksOnlyTheSettledMessageRead() async throws {
        ReaderRouteStub.route(
            "POST", "/api/messages/\(a)/action",
            json: MessageActionResponse(success: true, action: "mark_read", messageId: a, message: nil))
        let (session, _) = try makeSession(rows: [a, b], opening: a)
        session.didSettle(on: a)

        let marked = await waitUntil { ReaderRouteStub.recorded.contains(self.actionPath(self.a)) }
        XCTAssertTrue(marked, "the settled message was never marked read")
        let neighbourLoaded = await waitUntil { session.conversation(for: self.b) != nil }
        XCTAssertTrue(neighbourLoaded, "the neighbour was never prefetched, so this proves nothing about it")
        XCTAssertFalse(ReaderRouteStub.recorded.contains(actionPath(b)))
    }

    /// With the conversation and its reference data already cached, the page's first document is
    /// the conversation itself — not a loading placeholder followed by a second load — and the
    /// copy is still checked against the server behind it.
    func testACachedConversationIsTheFirstDocumentAndIsRevalidated() async throws {
        let threadCache = MVThreadCache(fetch: { _ in ThreadResponse(messages: []) })
        threadCache.store(ThreadResponse(messages: [message(a, seen: true)]), for: a)
        ReaderRouteStub.route("GET", "/api/accounts/\(ReaderFixtures.accountId)/folders", json: [FolderResponse]())
        ReaderRouteStub.route("GET", "/api/contacts/photo-index", json: ContactPhotoIndexResponse(byEmail: [:]))
        let referenceCache = MVReferenceCache(backend: try makeClient())
        _ = await referenceCache.fetchFolders(accountId: ReaderFixtures.accountId)
        _ = await referenceCache.fetchPhotoIndex(accountId: ReaderFixtures.accountId)
        let (session, _) = try makeSession(
            rows: [a], opening: a, seen: true, threadCache: threadCache, referenceCache: referenceCache)
        let threadPath = "GET /api/messages/\(a)/thread"
        XCTAssertFalse(ReaderRouteStub.recorded.contains(threadPath))

        let first = session.document(for: a)

        XCTAssertTrue(first.revealsOpened, "the first document was a placeholder, not the cached conversation")
        XCTAssertNotNil(session.conversation(for: a))
        let revalidated = await waitUntil { ReaderRouteStub.recorded.contains(threadPath) }
        XCTAssertTrue(revalidated, "the cached copy was never checked against the server")
    }

    /// A cached copy can say read when the message is unread again — marked unread on another
    /// device, say. Opening it must still mark it read, from the server's answer, not skip it on
    /// the strength of the copy.
    func testACachedCopySayingReadStillMarksAnUnreadMessageRead() async throws {
        ReaderRouteStub.route(
            "POST", "/api/messages/\(a)/action",
            json: MessageActionResponse(success: true, action: "mark_read", messageId: a, message: nil))
        let threadCache = MVThreadCache(fetch: { _ in ThreadResponse(messages: []) })
        threadCache.store(ThreadResponse(messages: [message(a, seen: true)]), for: a)
        ReaderRouteStub.route("GET", "/api/accounts/\(ReaderFixtures.accountId)/folders", json: [FolderResponse]())
        ReaderRouteStub.route("GET", "/api/contacts/photo-index", json: ContactPhotoIndexResponse(byEmail: [:]))
        let referenceCache = MVReferenceCache(backend: try makeClient())
        _ = await referenceCache.fetchFolders(accountId: ReaderFixtures.accountId)
        _ = await referenceCache.fetchPhotoIndex(accountId: ReaderFixtures.accountId)
        let (session, _) = try makeSession(
            rows: [a], opening: a, seen: false, threadCache: threadCache, referenceCache: referenceCache)

        session.didSettle(on: a)

        XCTAssertNotNil(session.conversation(for: a), "the cached copy was not drawn, so this proves nothing")
        let marked = await waitUntil { ReaderRouteStub.recorded.contains(self.actionPath(self.a)) }
        XCTAssertTrue(marked, "the stale cached read state kept the message from being marked read")
    }

    func testAnExplicitlyUnreadMessageIsNotMarkedReadAgain() async throws {
        let tracker = MVExplicitUnreadTracker()
        await tracker.markExplicit(a)
        let (session, _) = try makeSession(rows: [a], opening: a, tracker: tracker)
        session.didSettle(on: a)

        let rulesRan = await waitUntil { ReaderRouteStub.recorded.contains("GET /api/alerts") }
        XCTAssertTrue(rulesRan, "the settle rules never ran")
        XCTAssertFalse(ReaderRouteStub.recorded.contains(actionPath(a)))
    }

    /// The row opens on its own (newest) message; switching to an older message of the same
    /// thread makes it the primary — what Reply targets, and what gets marked read — while the
    /// row itself (`a`) stays exactly where the pager left it.
    func testOpeningAnOlderMessageOfTheThreadBecomesPrimaryAndIsMarkedRead() async throws {
        let older = message(b, seen: false)
        let newer = message(a, seen: true)
        ReaderRouteStub.route(
            "POST", "/api/messages/\(b)/action",
            json: MessageActionResponse(success: true, action: "mark_read", messageId: b, message: nil))
        let (session, _) = try makeSession(rows: [a], opening: a, seen: true)
        ReaderRouteStub.route("GET", "/api/messages/\(a)/thread", json: ThreadResponse(messages: [older, newer]))
        session.didSettle(on: a)
        let loaded = await waitUntil { session.conversation(for: self.a) != nil }
        XCTAssertTrue(loaded)
        XCTAssertEqual(session.currentPrimary?.id, a, "the row did not open on its own newest message")

        session.openMessage(b)

        XCTAssertEqual(session.currentRowId, a, "switching the open message moved the pager off its row")
        XCTAssertEqual(session.currentPrimary?.id, b)
        XCTAssertEqual(session.composeIntent(for: .reply)?.kind, .reply(messageId: b))
        let marked = await waitUntil { ReaderRouteStub.recorded.contains(self.actionPath(self.b)) }
        XCTAssertTrue(marked, "opening an unread older message never marked it read")
    }

    /// Archiving, deleting or junking the open message when it is not the row's own must leave
    /// the row (and the rest of the pager) exactly where it was — only the message itself leaves
    /// its folder, the same as the web, where the conversation's row survives.
    func testArchivingANonRowMessageKeepsTheRowInThePager() async throws {
        let older = message(b, seen: false)
        let newer = message(a, seen: true)
        ReaderRouteStub.route(
            "POST", "/api/messages/\(b)/action",
            json: MessageActionResponse(success: true, action: "archive", messageId: b, message: nil))
        let (session, _) = try makeSession(rows: [a], opening: a, seen: true)
        ReaderRouteStub.route("GET", "/api/messages/\(a)/thread", json: ThreadResponse(messages: [older, newer]))
        session.didSettle(on: a)
        let loaded = await waitUntil { session.conversation(for: self.a) != nil }
        XCTAssertTrue(loaded)
        session.openMessage(b)
        XCTAssertEqual(session.currentPrimary?.id, b)

        XCTAssertEqual(session.remove(with: .archive), .stay)

        XCTAssertEqual(session.currentRowId, a, "archiving the open message moved the pager off its row")
        XCTAssertFalse(session.paging.removedIds.contains(a), "the row itself was removed from the pager")
        let archived = await waitUntil { ReaderRouteStub.recorded.contains(self.actionPath(self.b)) }
        XCTAssertTrue(archived, "the open message was never archived")
        XCTAssertFalse(
            ReaderRouteStub.recorded.contains(actionPath(a)), "the row's own message was archived instead")
    }

    /// A refresh must carry the currently open message forward rather than snapping back to the
    /// row's own — a new reply arriving over SSE, or a cached copy revalidated behind the first
    /// document, both go through the same `refresh(_:)`.
    func testRefreshingAfterOpeningAnOlderMessageKeepsItOpenWhenTheThreadGrows() async throws {
        let older = message(b, seen: true)
        let newer = message(a, seen: true)
        let (session, _) = try makeSession(rows: [a], opening: a, seen: true)
        ReaderRouteStub.route("GET", "/api/messages/\(a)/thread", json: ThreadResponse(messages: [older, newer]))
        session.didSettle(on: a)
        let loaded = await waitUntil { session.conversation(for: self.a) != nil }
        XCTAssertTrue(loaded)
        session.openMessage(b)
        XCTAssertEqual(session.currentPrimary?.id, b)

        let reply = message(c, seen: true)
        ReaderRouteStub.route(
            "GET", "/api/messages/\(a)/thread", json: ThreadResponse(messages: [older, newer, reply]))
        var refreshed = false
        session.refresh(a) { refreshed = true }
        let done = await waitUntil { refreshed }
        XCTAssertTrue(done)

        XCTAssertEqual(session.currentPrimary?.id, b, "a live refresh snapped the open message back to the row's own")
        XCTAssertEqual(session.conversation(for: a)?.messageIds.count, 3)
    }

    /// `applyReadRules` dismisses a settled row's own unseen alerts; opening a different message
    /// of the same thread must do the same for that message.
    func testOpeningAnOlderMessageDismissesItsOwnUnseenAlerts() async throws {
        let older = message(b, seen: true)
        let newer = message(a, seen: true)
        let (session, _) = try makeSession(rows: [a], opening: a, seen: true)
        ReaderRouteStub.route("GET", "/api/messages/\(a)/thread", json: ThreadResponse(messages: [older, newer]))
        session.didSettle(on: a)
        let loaded = await waitUntil { session.conversation(for: self.a) != nil }
        XCTAssertTrue(loaded)
        let rulesRan = await waitUntil { ReaderRouteStub.recorded.contains("GET /api/alerts") }
        XCTAssertTrue(rulesRan, "the settle rules never ran")

        let alertId = UUID()
        let alert = AlertResponse(
            id: alertId, kind: "new_mail", title: nil, body: nil, url: nil, accountId: nil, messageId: b,
            folderId: nil, deliveredAt: nil, dismissedAt: nil, createdAt: Date())
        ReaderRouteStub.route("GET", "/api/alerts", json: [alert])
        ReaderRouteStub.route("POST", "/api/alerts/\(alertId)/dismiss", body: Data())

        session.openMessage(b)

        let dismissed = await waitUntil { ReaderRouteStub.recorded.contains("POST /api/alerts/\(alertId)/dismiss") }
        XCTAssertTrue(dismissed, "opening an older message never dismissed its own unseen alert")
    }

    func testArchivingAdvancesAtOnceAndAFailedRequestPutsTheMessageBack() async throws {
        ReaderRouteStub.route(
            "POST", "/api/messages/\(b)/action", status: 500, body: Data(#"{"detail":"server down"}"#.utf8))
        // Already read, so the only request this page makes to the failing route is the archive.
        let (session, _) = try makeSession(rows: [a, b, c], opening: b, seen: true)
        var toasts: [String] = []
        session.onToast = { toasts.append($0.message) }
        session.didSettle(on: b)
        let loaded = await waitUntil { session.conversation(for: self.b) != nil }
        XCTAssertTrue(loaded)

        XCTAssertEqual(session.remove(with: .archive), .advance(to: c, direction: .older))
        XCTAssertTrue(session.paging.removedIds.contains(b))

        let restored = await waitUntil { !session.paging.removedIds.contains(self.b) }
        XCTAssertTrue(restored, "a failed archive left the message out of the pager")
        XCTAssertEqual(toasts, ["Could not archive: server down"])
    }
}
