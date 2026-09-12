import XCTest
@testable import MailVerdictKit

final class PersistedPathTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "PersistedPathTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testSavingAndLoadingRoundTrips() {
        let defaults = makeDefaults()
        let folderId = UUID(), accountId = UUID()
        let routes: [Route] = [.list(.folder(accountId: accountId, folderId: folderId), aroundMessageId: nil)]

        MVPersistedPath.save(routes, to: defaults)

        XCTAssertEqual(MVPersistedPath.load(from: defaults), routes)
    }

    func testNothingSavedLoadsAsEmpty() {
        XCTAssertEqual(MVPersistedPath.load(from: makeDefaults()), [])
    }

    /// Cold launch restores the list at most, never a reader — Apple Mail's own behaviour.
    func testAReaderIsStrippedFromTheSavedPath() {
        let scope = ListScope.folder(accountId: UUID(), folderId: UUID())
        let messageId = UUID()
        let routes: [Route] = [
            .list(scope, aroundMessageId: nil),
            .reader(ReaderContext(source: .list(scope), messageId: messageId)),
        ]
        XCTAssertEqual(
            MVPersistedPath.sanitizedForColdLaunch(routes), [.list(scope, aroundMessageId: nil)]
        )
    }

    func testAPathWithNoReaderIsUnchanged() {
        let routes: [Route] = [.settings, .accounts]
        XCTAssertEqual(MVPersistedPath.sanitizedForColdLaunch(routes), routes)
    }

    func testSavingStripsTheReaderBeforePersistingToo() {
        let defaults = makeDefaults()
        let scope = ListScope.folder(accountId: UUID(), folderId: UUID())
        let routes: [Route] = [
            .list(scope, aroundMessageId: nil),
            .reader(ReaderContext(source: .list(scope), messageId: UUID())),
        ]
        MVPersistedPath.save(routes, to: defaults)
        XCTAssertEqual(MVPersistedPath.load(from: defaults), [.list(scope, aroundMessageId: nil)])
    }
}
