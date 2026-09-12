import XCTest

@testable import MailVerdictKit

@MainActor
final class MVAccountDetailStoreTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore(accountId: UUID = UUID()) -> MVAccountDetailStore {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        return MVAccountDetailStore(accountId: accountId, apiClient: client)
    }

    private func accountJSON(id: UUID, name: String = "Work") -> String {
        """
        {"id":"\(id)","name":"\(name)","imap_host":"imap.example.com","imap_port":993,
        "imap_user":"me@example.com","smtp_host":null,"smtp_port":null,"smtp_user":null,
        "is_active":true,"state":"active","state_error":null,"capabilities":null,
        "created_at":"2026-01-01T00:00:00+00:00","updated_at":"2026-01-01T00:00:00+00:00",
        "emoji":null,"spam_enabled":false,"folder_order":null,"trash_retention_days":null,
        "junk_retention_days":null}
        """
    }

    func testLoadedStateCarriesTheAccount() async {
        let id = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(accountJSON(id: id).utf8))

        let store = makeStore(accountId: id)
        await store.load()

        guard case .loaded(let account) = store.state else {
            XCTFail("expected .loaded, got \(store.state)")
            return
        }
        XCTAssertEqual(account.id, id)
        XCTAssertEqual(store.account?.id, id)
    }

    func testAccountsChangedRefreshFindsTheAccountGoneAndSetsWasDeletedElsewhere() async {
        let id = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(accountJSON(id: id).utf8))
        let store = makeStore(accountId: id)
        await store.load()
        XCTAssertFalse(store.wasDeletedElsewhere)

        MVStubURLProtocol.stub = .init(
            statusCode: 404, headers: [:], body: Data("{\"detail\":\"not found\"}".utf8))
        store.apply([.accountsChanged])

        await waitUntil { store.wasDeletedElsewhere }
        // The account that was on screen stays on screen — the screen pops itself rather than
        // this store clearing what it last knew.
        XCTAssertEqual(store.account?.id, id)
    }

    func testAccountsChangedRefreshReplacesTheAccountOnSuccess() async {
        let id = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(accountJSON(id: id).utf8))
        let store = makeStore(accountId: id)
        await store.load()

        MVStubURLProtocol.stub = .init(
            statusCode: 200, headers: [:], body: Data(accountJSON(id: id, name: "Renamed").utf8))
        store.apply([.accountsChanged])

        await waitUntil { store.account?.name == "Renamed" }
        XCTAssertFalse(store.wasDeletedElsewhere)
    }

    func testUnrelatedInvalidationNeverTriggersARequest() async {
        let id = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(accountJSON(id: id).utf8))
        let store = makeStore(accountId: id)
        await store.load()

        MVStubURLProtocol.reset()
        store.apply([.resync])

        // Give the main actor a turn; nothing here is async on a real mutation, but this proves
        // a future change that drops the `accountsChanged` guard would be caught: any request at
        // all records a capturedRequest.
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(MVStubURLProtocol.capturedRequest)
    }

    func testSetActiveRollsBackOnFailure() async {
        let id = UUID()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(accountJSON(id: id).utf8))
        let store = makeStore(accountId: id)
        await store.load()
        XCTAssertEqual(store.account?.isActive, true)

        MVStubURLProtocol.stub = .init(statusCode: 500, headers: [:], body: Data())
        do {
            try await store.setActive(false)
            XCTFail("expected the update to throw")
        } catch {
            // expected
        }
        XCTAssertEqual(store.account?.isActive, true)
    }
}
