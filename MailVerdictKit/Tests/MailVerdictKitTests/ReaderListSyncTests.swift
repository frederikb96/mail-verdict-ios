import XCTest

@testable import MailVerdictKit

/// The reader acting on a message the list shows: the list's row reflects it in the same turn —
/// never a round trip and a live event later — and goes back when the request fails. The two
/// share the connection's one ledger, as in the app.
@MainActor
final class ReaderListSyncTests: XCTestCase {
    private let first = testUUID(1)
    private let second = testUUID(2)

    override func setUp() async throws {
        ReaderRouteStub.reset()
    }

    private func detail(_ id: UUID) -> MessageDetail {
        ReaderFixtures.message(
            id: id, from: "Alice <alice@example.org>", to: [], subject: "s", html: "<p>x</p>", text: nil, minutesAgo: 1,
            isSeen: true)
    }

    private func makeClient() throws -> MVApiClient {
        MVApiClient(
            requestFactory: try MVRequestFactory(baseURL: "https://mail.example", authProvider: { .none }),
            urlSession: ReaderRouteStub.makeSession())
    }

    private func makeReader(
        rows: [MessageSummary], opening: UUID, ledger: MVIntentLedger? = nil
    ) async throws -> (ReaderSession, MVMailListStore) {
        for row in rows {
            ReaderRouteStub.route(
                "GET", "/api/messages/\(row.id)/thread", json: ThreadResponse(messages: [detail(row.id)]))
        }
        ReaderRouteStub.route("GET", "/api/accounts/\(ReaderFixtures.accountId)/folders", json: [FolderResponse]())
        ReaderRouteStub.route("GET", "/api/contacts/photo-index", json: ContactPhotoIndexResponse(byEmail: [:]))
        ReaderRouteStub.route("GET", "/api/alerts", json: [AlertResponse]())

        let client = try makeClient()
        let ledger = ledger ?? makeTestLedger(transport: client)
        let backend = FakeMailListBackend()
        backend.pageHandler = { _, _ in testPage(rows) }
        let scope = ListScope.folder(accountId: testAccount, folderId: testFolder)
        let store = MVMailListStore(
            scope: scope, backend: backend, ledger: ledger, toasts: nil, defaults: testDefaults(threaded: false),
            session: MVListSession())
        await store.start()

        let registry = ReaderSourceRegistry()
        let context = ReaderContext(source: .list(scope), messageId: opening)
        registry.register(store, for: context.source)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reader-list-sync-\(UUID())"))
        let session = ReaderSession(
            context: context, api: client, ledger: ledger, placeResolver: MVMessagePlaceResolver(apiClient: client),
            theme: .light,
            registry: registry, tracker: MVExplicitUnreadTracker(),
            canvasStore: MVCanvasPreferenceStore(defaults: defaults),
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        session.didSettle(on: opening)
        await waitUntil { session.conversation(for: opening) != nil }
        return (session, store)
    }

    /// Archiving the only message closes the reader onto the list, which must already be without
    /// it.
    func testArchivingTheLastMessageTakesItOutOfTheListBeforeTheReaderCloses() async throws {
        ReaderRouteStub.route(
            "POST", "/api/messages/\(first)/action", status: 409, body: Data(#"{"detail":"Message is locked"}"#.utf8))
        let (session, store) = try await makeReader(rows: [testRow(1)], opening: first)

        XCTAssertEqual(session.remove(with: .archive), .close)

        XCTAssertEqual(store.rowIds, [], "the list still showed the archived row when the reader closed")
        await waitUntil { store.rowIds == [self.first] }
        XCTAssertEqual(store.rowIds, [first], "a failed archive left the row out of the list")
    }

    func testStarringFromTheReaderStarsTheListRowAndAFailurePutsItBack() async throws {
        let (session, store) = try await makeReader(rows: [testRow(1), testRow(2)], opening: second)
        ReaderRouteStub.route(
            "POST", "/api/messages/\(second)/action", status: 409, body: Data(#"{"detail":"Message is locked"}"#.utf8))

        await session.setStarred(true)

        XCTAssertEqual(store.row(id: second)?.isFlagged, true, "the list row was not starred while the request was out")
        await waitUntil { store.row(id: self.second)?.isFlagged == false }
        XCTAssertEqual(store.row(id: second)?.isFlagged, false, "a failed star left the list row starred")
    }

    func testMarkingUnreadFromTheReaderUpdatesTheListRow() async throws {
        let (session, store) = try await makeReader(rows: [testRow(1, seen: true)], opening: first)
        ReaderRouteStub.route(
            "POST", "/api/messages/\(first)/action",
            json: MessageActionResponse(success: true, action: "mark_unread", messageId: first, message: nil))

        await session.setRead(false)

        XCTAssertEqual(store.row(id: first)?.isSeen, false)
    }

    func testMovingFromTheReaderTakesTheRowOutOfTheList() async throws {
        ReaderRouteStub.route(
            "POST", "/api/messages/\(second)/action",
            json: MessageActionResponse(success: true, action: "move", messageId: second, message: nil))
        let (session, store) = try await makeReader(rows: [testRow(1), testRow(2)], opening: second)

        XCTAssertEqual(
            session.remove(with: .move, targetFolderId: testUUID(42)), .advance(to: first, direction: .newer))

        XCTAssertEqual(store.rowIds, [first])
    }

    /// What the reader shows reads through the ledger as well as the list: its Options menu says
    /// Unstar the moment Star is tapped.
    func testTheReaderShowsItsOwnStarAtOnce() async throws {
        let gate = TestGate()
        let transport = RecordingIntentTransport()
        transport.handler = { _ in await gate.wait() }
        let (session, _) = try await makeReader(
            rows: [testRow(1)], opening: first, ledger: makeTestLedger(transport: transport))

        await session.setStarred(true)

        XCTAssertEqual(session.currentPrimary?.isFlagged, true)
        XCTAssertEqual(session.optionsContext()?.isStarred, true)
        await gate.open()
    }

    func testUndoingAnArchiveFromTheReaderMovesTheMessageBackToItsFolder() async throws {
        let toasts = MVToastStore()
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport, toasts: toasts)
        let (session, _) = try await makeReader(rows: [testRow(1), testRow(2)], opening: first, ledger: ledger)

        _ = session.remove(with: .archive)
        await waitUntil { ledger.intents.first?.state == .done }
        XCTAssertEqual(toasts.current?.actionTitle, "Undo")
        toasts.current?.action?()
        await waitUntil { transport.calls.count == 2 }

        XCTAssertEqual(transport.calls, ["archive 1", "move 1"])
        XCTAssertEqual(ledger.intents.last?.targetFolderId, ReaderFixtures.inboxId)
    }

    /// A page read before a star reached the server keeps showing it after the star leaves the
    /// ledger, rather than dropping back to what that older read said.
    func testAPageKeepsAStarOnceItsIntentRetires() async throws {
        let clock = TestIntentClock()
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport, clock: clock)
        let (session, _) = try await makeReader(rows: [testRow(1)], opening: first, ledger: ledger)

        await session.setStarred(true)
        await waitUntil { ledger.intents.first?.state == .done && clock.sleeperCount == 1 }
        clock.advance(by: MVIntentLedger.Timing().doneRetention)
        await waitUntil { ledger.intents.isEmpty }

        XCTAssertEqual(session.currentPrimary?.isFlagged, true)
    }

    /// The reader opening a message joins a prefetch that left before a star reached the server;
    /// what that fetch brings back predates the star, so the star still applies over it.
    func testAConversationFetchedBeforeAStarLandedStillShowsTheStar() async throws {
        let gate = TestGate()
        let fetchedBefore = ThreadResponse(messages: [detail(first)])
        let threadCache = MVThreadCache(fetch: { _ in
            await gate.wait()
            return fetchedBefore
        })
        ReaderRouteStub.route("GET", "/api/accounts/\(ReaderFixtures.accountId)/folders", json: [FolderResponse]())
        ReaderRouteStub.route("GET", "/api/contacts/photo-index", json: ContactPhotoIndexResponse(byEmail: [:]))
        let client = try makeClient()
        let transport = RecordingIntentTransport()
        let ledger = makeTestLedger(transport: transport)

        threadCache.prefetchUrgently(first)
        ledger.enqueue(
            MVIntentRequest(accountId: ReaderFixtures.accountId, action: .flag, messageIds: [first]))
        await waitUntil { ledger.intents.first?.state == .done }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reader-list-sync-\(UUID())"))
        let session = ReaderSession(
            context: ReaderContext(source: .spamReview, messageId: first), api: client, ledger: ledger,
            placeResolver: MVMessagePlaceResolver(apiClient: client), theme: .light, registry: ReaderSourceRegistry(),
            tracker: MVExplicitUnreadTracker(), canvasStore: MVCanvasPreferenceStore(defaults: defaults),
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            threadCache: threadCache)
        session.ensureLoaded(first)
        await gate.open()
        await waitUntil { session.conversation(for: self.first) != nil }

        XCTAssertEqual(session.conversation(for: first)?.primary?.isFlagged, true)
    }
}
