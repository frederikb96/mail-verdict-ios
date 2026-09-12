import XCTest
@testable import MailVerdictKit

private struct StubMembership: MVUnifiedViewMembershipLookup {
    let ref: MVUnifiedViewRef?
    func mostRecentUnifiedView(containingFolderId folderId: UUID) -> MVUnifiedViewRef? { ref }
}

final class MessagePlaceResolverScopeTests: XCTestCase {

    func testOpensInItsOwnFolderWhenTheLastViewWasNotUnified() {
        let accountId = UUID(), folderId = UUID()
        let location = MessageLocation(id: UUID(), accountId: accountId, folderId: folderId, threadId: UUID())
        let scope = MVMessagePlaceResolver.resolveScope(
            location: location, lastViewWasUnified: false,
            membership: StubMembership(ref: MVUnifiedViewRef(id: UUID(), name: "Everything"))
        )
        XCTAssertEqual(scope, .folder(accountId: accountId, folderId: folderId))
    }

    func testOpensInTheMostRecentUnifiedViewWhenTheLastViewWasUnifiedAndItContainsTheFolder() {
        let accountId = UUID(), folderId = UUID()
        let location = MessageLocation(id: UUID(), accountId: accountId, folderId: folderId, threadId: UUID())
        let ref = MVUnifiedViewRef(id: UUID(), name: "Everything")
        let scope = MVMessagePlaceResolver.resolveScope(
            location: location, lastViewWasUnified: true, membership: StubMembership(ref: ref)
        )
        XCTAssertEqual(scope, .unified(viewId: ref.id, name: ref.name))
    }

    func testFallsBackToItsOwnFolderWhenNoUnifiedViewContainsIt() {
        let accountId = UUID(), folderId = UUID()
        let location = MessageLocation(id: UUID(), accountId: accountId, folderId: folderId, threadId: UUID())
        let scope = MVMessagePlaceResolver.resolveScope(
            location: location, lastViewWasUnified: true, membership: StubMembership(ref: nil)
        )
        XCTAssertEqual(scope, .folder(accountId: accountId, folderId: folderId))
    }

    func testFallsBackToItsOwnFolderWhenNoMembershipLookupIsWiredYet() {
        let accountId = UUID(), folderId = UUID()
        let location = MessageLocation(id: UUID(), accountId: accountId, folderId: folderId, threadId: UUID())
        let scope = MVMessagePlaceResolver.resolveScope(location: location, lastViewWasUnified: true, membership: nil)
        XCTAssertEqual(scope, .folder(accountId: accountId, folderId: folderId))
    }
}

final class MessagePlaceResolverEndToEndTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    func testResolveBuildsTheListThenReaderPath() async throws {
        let accountId = UUID(), folderId = UUID(), threadId = UUID(), messageId = UUID()
        let json = """
            {"id":"\(messageId)","account_id":"\(accountId)","folder_id":"\(folderId)","thread_id":"\(threadId)"}
            """
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(json.utf8))

        let factory = try MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        let resolver = MVMessagePlaceResolver(apiClient: client)

        let result = await resolver.resolve(messageId: messageId)
        let scope = ListScope.folder(accountId: accountId, folderId: folderId)
        XCTAssertEqual(
            result,
            .route([
                .list(scope, aroundMessageId: messageId),
                .reader(ReaderContext(source: .list(scope), messageId: messageId)),
            ])
        )
    }

    func testA404BecomesTheNotFoundToast() async throws {
        MVStubURLProtocol.stub = .init(
            statusCode: 404, headers: [:], body: Data(#"{"detail":"Message not found"}"#.utf8))
        let factory = try MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        let resolver = MVMessagePlaceResolver(apiClient: client)

        let result = await resolver.resolve(messageId: UUID())
        XCTAssertEqual(result, .notFound(toastMessage: "That message no longer exists"))
    }
}

final class RecentViewRecordTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "RecentViewRecordTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testRecordingAFolderViewClearsTheUnifiedFlag() {
        let record = MVRecentViewRecord(defaults: makeDefaults())
        record.recordUnifiedView(MVUnifiedViewRef(id: UUID(), name: "Everything"))
        XCTAssertTrue(record.lastViewWasUnified)
        record.recordFolderView()
        XCTAssertFalse(record.lastViewWasUnified)
    }

    func testRecentUnifiedViewsAreMostRecentFirstAndCappedAtFive() {
        let record = MVRecentViewRecord(defaults: makeDefaults())
        let refs = (0..<7).map { MVUnifiedViewRef(id: UUID(), name: "View \($0)") }
        for ref in refs { record.recordUnifiedView(ref) }

        let recent = record.recentUnifiedViews()
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.first, refs.last)
    }

    func testReopeningTheSameViewMovesItToTheFront() {
        let record = MVRecentViewRecord(defaults: makeDefaults())
        let a = MVUnifiedViewRef(id: UUID(), name: "A")
        let b = MVUnifiedViewRef(id: UUID(), name: "B")
        record.recordUnifiedView(a)
        record.recordUnifiedView(b)
        record.recordUnifiedView(a)

        XCTAssertEqual(record.recentUnifiedViews(), [a, b])
    }
}
