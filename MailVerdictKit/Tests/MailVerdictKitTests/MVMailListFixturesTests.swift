#if DEBUG

    import XCTest

    @testable import MailVerdictKit

    /// The screenshot sweep shows whatever these routes answer; a body the client cannot decode
    /// would show an error screen that still screenshots as a well-formed screen.
    final class MVMailListFixturesTests: XCTestCase {

        override func tearDown() {
            MVFixtureURLProtocol.resetToDefaults()
            super.tearDown()
        }

        private func decode<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            let match = MVFixtureURLProtocol.route(method: "GET", path: path)
            XCTAssertEqual(match.status, 200, path)
            return try JSONDecoder.mvDefault.decode(T.self, from: match.body())
        }

        func testEveryListRouteDecodesAsTheClientReadsIt() throws {
            MVMailListFixtures.register()
            let account = MVMailListFixtures.accountId

            let page = try decode(MessageListResponse.self, "/api/accounts/\(account)/messages")
            XCTAssertFalse(page.messages.isEmpty)
            XCTAssertFalse(page.hasMore)
            XCTAssertEqual(Set(page.messages.map(\.id)).count, page.messages.count)

            XCTAssertEqual(try decode([AccountResponse].self, "/api/accounts").first?.id, account)
            XCTAssertTrue(
                try decode([FolderResponse].self, "/api/accounts/\(account)/folders").contains {
                    $0.id == MVMailListFixtures.folderId
                })
            XCTAssertFalse(
                try decode(FolderOrderResponse.self, "/api/accounts/\(account)/folder-order").folders.isEmpty)
            _ = try decode(SelectionSnapshotResponse.self, "/api/accounts/\(account)/messages/selection")
            _ = try decode([OutboxResponse].self, "/api/outbox")
            _ = try decode([UnifiedFolderResponse].self, "/api/unified/folders")
            _ = try decode(SearchResponse.self, "/api/search")
        }
    }

#endif
