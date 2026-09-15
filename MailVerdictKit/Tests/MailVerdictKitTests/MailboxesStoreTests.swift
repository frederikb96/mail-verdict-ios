import Observation
import XCTest

@testable import MailVerdictKit

/// A `withObservationTracking` `onChange` handler is `@Sendable`; this is the reference-type flag
/// it sets, mutated only from this actor in practice.
private final class ObservationFlag: @unchecked Sendable {
    var value = false
}

@MainActor
final class MailboxesStoreTests: XCTestCase {

    private func makeStore() -> MailboxesStore {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        let suite = try! XCTUnwrap(UserDefaults(suiteName: "mailboxes-store-\(UUID())"))
        return MailboxesStore(
            apiClient: client, uiState: MailboxesUIState(defaults: suite),
            diskCache: MailboxesDiskCache(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            recentViews: MVRecentViewRecord(defaults: suite))
    }

    /// `isCollapsed`/`toggleCollapsed` used to read and write straight through to `UserDefaults`,
    /// which Swift's Observation framework never sees — so `MailboxesScreen`'s section content
    /// (driven by `store.isCollapsed(_:)`) never re-rendered after a tap, and the chevron never
    /// moved either. Collapse state has to live in the store's own `@Observable` storage for
    /// SwiftUI to notice it changed at all.
    func testTogglingCollapseNotifiesObservers() async {
        let store = makeStore()
        let key = MailboxesUIState.accountKey(UUID())
        XCTAssertFalse(store.isCollapsed(key))

        // `onChange` is `@Sendable`, so the flag it sets needs a reference type rather than a
        // captured `var` — the mutation itself still happens synchronously, on this actor, inside
        // `toggleCollapsed` below.
        let notified = ObservationFlag()
        withObservationTracking {
            _ = store.isCollapsed(key)
        } onChange: {
            notified.value = true
        }
        store.toggleCollapsed(key)

        XCTAssertTrue(notified.value, "collapsing a section never notified an observer reading isCollapsed(_:)")
        XCTAssertTrue(store.isCollapsed(key))
    }

    /// Collapse state has to survive a relaunch, which the `@Observable` mirror only does if it is
    /// actually seeded from the persisted store at init — a plain `= []` would drop it silently.
    func testCollapseStateSurvivesARelaunch() async {
        let suite = try! XCTUnwrap(UserDefaults(suiteName: "mailboxes-store-\(UUID())"))
        let key = MailboxesUIState.accountKey(UUID())
        MailboxesUIState(defaults: suite).setCollapsed(true, forKey: key)

        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        let relaunched = MailboxesStore(
            apiClient: client, uiState: MailboxesUIState(defaults: suite),
            diskCache: MailboxesDiskCache(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            recentViews: MVRecentViewRecord(defaults: suite))

        XCTAssertTrue(relaunched.isCollapsed(key), "a relaunch lost collapse state persisted by an earlier instance")
    }
}
