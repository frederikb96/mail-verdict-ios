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

    /// `FixtureBootstrap` clears the app's own persistent domain at launch, in `MailVerdict/`
    /// where `Bundle.main` actually means something — this is the one piece of that fix a
    /// package test can still prove: a previously-saved path is gone once the domain backing
    /// `UserDefaults` is removed, the exact mechanism that keeps one fixture screenshot's
    /// navigation state (and a store's own search/collapse/scroll state alongside it) from
    /// surviving into the next screenshot's launch.
    func testLoadReturnsEmptyAfterThePersistentDomainIsCleared() {
        let suite = "PersistedPathTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        MVPersistedPath.save([.settings], to: defaults)
        XCTAssertFalse(MVPersistedPath.load(from: defaults).isEmpty)

        defaults.removePersistentDomain(forName: suite)

        XCTAssertTrue(MVPersistedPath.load(from: defaults).isEmpty)
    }
}
