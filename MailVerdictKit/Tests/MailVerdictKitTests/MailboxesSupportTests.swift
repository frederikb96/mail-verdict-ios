import XCTest
@testable import MailVerdictKit

// Connection-state classification (`MVAccountConnectionState.classify`) lives in
// `Stores/Accounts/` — Mailboxes only consumes it, and its own tests belong with that type.

final class MailboxesSupportOrderFoldersTests: XCTestCase {

    private func folder(
        _ name: String, specialUse: String? = nil, isVisible: Bool = true
    ) -> FolderOrderItem {
        FolderOrderItem(
            folderId: UUID(), imapName: name, displayName: name, specialUse: specialUse,
            isVisible: isVisible
        )
    }

    func testWithASavedOrderOnlyInboxMovesToTheFront() {
        let archive = folder("Archive", specialUse: "archive")
        let inbox = folder("INBOX", specialUse: "inbox")
        let sent = folder("Sent", specialUse: "sent")
        let ordered = MailboxesSupport.orderFolders([archive, inbox, sent], hasCustomOrder: true)
        XCTAssertEqual(ordered.map(\.imapName), ["INBOX", "Archive", "Sent"])
    }

    func testWithoutASavedOrderTheFullWebLeadSequenceApplies() {
        let archive = folder("Archive", specialUse: "archive")
        let inbox = folder("INBOX", specialUse: "inbox")
        let sent = folder("Sent", specialUse: "sent")
        let ordered = MailboxesSupport.orderFolders([archive, inbox, sent], hasCustomOrder: false)
        XCTAssertEqual(ordered.map(\.imapName), ["INBOX", "Sent", "Archive"])
    }

    func testLeavesAnAlreadyLeadingInboxAlone() {
        let inbox = folder("INBOX", specialUse: "inbox")
        let archive = folder("Archive", specialUse: "archive")
        let ordered = MailboxesSupport.orderFolders([inbox, archive], hasCustomOrder: true)
        XCTAssertEqual(ordered.map(\.imapName), ["INBOX", "Archive"])
    }

    func testDropsHiddenFolders() {
        let inbox = folder("INBOX", specialUse: "inbox")
        let hidden = folder("Hidden", isVisible: false)
        let ordered = MailboxesSupport.orderFolders([inbox, hidden], hasCustomOrder: true)
        XCTAssertEqual(ordered.map(\.imapName), ["INBOX"])
    }
}

final class MailboxesSupportLeadOrderedFoldersTests: XCTestCase {

    private func folder(_ name: String, specialUse: String? = nil) -> FolderOrderItem {
        FolderOrderItem(folderId: UUID(), imapName: name, displayName: name, specialUse: specialUse)
    }

    /// Port of the web's `sortFolders` — Inbox, Drafts, Sent, Archive, Junk, Trash, in that order,
    /// whatever order they arrived in.
    func testSpecialUseFoldersLeadInTheWebsFixedSequence() {
        let trash = folder("Trash", specialUse: "trash")
        let archive = folder("Archive", specialUse: "archive")
        let sent = folder("Sent", specialUse: "sent")
        let inbox = folder("INBOX", specialUse: "inbox")
        let junk = folder("Junk", specialUse: "junk")
        let drafts = folder("Drafts", specialUse: "drafts")
        let ordered = MailboxesSupport.leadOrderedFolders([trash, archive, sent, inbox, junk, drafts])
        XCTAssertEqual(ordered.map(\.imapName), ["INBOX", "Drafts", "Sent", "Archive", "Junk", "Trash"])
    }

    func testRegularFoldersFollowTheLeadSequenceAlphabeticallyByImapName() {
        let inbox = folder("INBOX", specialUse: "inbox")
        let zebra = folder("Zebra")
        let apple = folder("Apple")
        let ordered = MailboxesSupport.leadOrderedFolders([zebra, inbox, apple])
        XCTAssertEqual(ordered.map(\.imapName), ["INBOX", "Apple", "Zebra"])
    }

    func testAnUnrecognisedSpecialUseStillLeadsAheadOfRegularFolders() {
        let inbox = folder("INBOX", specialUse: "inbox")
        let weird = folder("Weird", specialUse: "custom-role")
        let apple = folder("Apple")
        let ordered = MailboxesSupport.leadOrderedFolders([apple, weird, inbox])
        XCTAssertEqual(ordered.map(\.imapName), ["INBOX", "Weird", "Apple"])
    }

    /// The same function sorts `FolderResponse` too — the plain `/folders` list the notification
    /// folder picker reads, which carries no saved-order concept for `orderFolders` to fall back
    /// from in the first place.
    func testAlsoSortsThePlainFolderResponseShape() {
        func response(_ name: String, specialUse: String?) -> FolderResponse {
            FolderResponse(
                id: UUID(), accountId: UUID(), imapName: name, displayName: nil, specialUse: specialUse,
                mailboxId: nil, backfillTotal: nil, idleStatus: nil, lastSyncedAt: nil, syncError: nil,
                createdAt: nil)
        }
        let sent = response("Sent", specialUse: "sent")
        let inbox = response("INBOX", specialUse: "inbox")
        let projects = response("Projects", specialUse: nil)
        let ordered = MailboxesSupport.leadOrderedFolders([projects, sent, inbox])
        XCTAssertEqual(ordered.map(\.imapName), ["INBOX", "Sent", "Projects"])
    }
}

final class MailboxesSupportFolderBadgeTests: XCTestCase {

    func testDraftsShowsTheTotalCountNotTheUnreadCount() {
        XCTAssertEqual(
            MailboxesSupport.folderBadgeCount(specialUse: "drafts", unreadCount: 0, totalCount: 7), 7
        )
    }

    func testAnOrdinaryFolderShowsTheUnreadCount() {
        XCTAssertEqual(
            MailboxesSupport.folderBadgeCount(specialUse: "inbox", unreadCount: 3, totalCount: 50), 3
        )
    }
}

final class MailboxesSupportContributingAccountsTests: XCTestCase {

    private func account(_ id: UUID, name: String) -> AccountResponse {
        AccountResponse(
            id: id, name: name, imapHost: "h", imapPort: 993, imapUser: "u", smtpHost: nil,
            smtpPort: nil, smtpUser: nil, stateError: nil, capabilities: nil, createdAt: Date(),
            updatedAt: Date(), emoji: nil, folderOrder: nil, trashRetentionDays: nil,
            junkRetentionDays: nil
        )
    }

    func testDeduplicatesByAccountInFirstSeenOrder() {
        let a = UUID(), b = UUID()
        let accounts = [account(a, name: "A"), account(b, name: "B")]
        let view = UnifiedFolderResponse(
            id: UUID(), unifiedName: "Everything", emoji: nil,
            folders: [
                UnifiedFolderSource(
                    accountId: b, accountName: "B", accountEmoji: nil, folderId: UUID(), imapName: "INBOX",
                    specialUse: "inbox"
                ),
                UnifiedFolderSource(
                    accountId: a, accountName: "A", accountEmoji: nil, folderId: UUID(), imapName: "INBOX",
                    specialUse: "inbox"
                ),
                UnifiedFolderSource(
                    accountId: b, accountName: "B", accountEmoji: nil, folderId: UUID(), imapName: "Archive",
                    specialUse: "archive"
                ),
            ],
            unreadCount: 0, totalCount: 0
        )
        let contributing = MailboxesSupport.contributingAccounts(for: view, accounts: accounts)
        XCTAssertEqual(contributing.map(\.id), [b, a])
    }

    func testSkipsAFolderSourceWithNoMatchingAccount() {
        let view = UnifiedFolderResponse(
            id: UUID(), unifiedName: "Everything", emoji: nil,
            folders: [
                UnifiedFolderSource(
                    accountId: UUID(), accountName: "Gone", accountEmoji: nil, folderId: UUID(),
                    imapName: "INBOX", specialUse: "inbox"
                )
            ],
            unreadCount: 0, totalCount: 0
        )
        XCTAssertEqual(MailboxesSupport.contributingAccounts(for: view, accounts: []), [])
    }
}

final class MailboxesSupportDeadOutboxBannerTests: XCTestCase {

    func testNilWhenThereIsNothingDead() {
        XCTAssertNil(MailboxesSupport.deadOutboxBannerText(messageCount: 0, accountNames: []))
    }

    func testSingularMessageNamesThisAccountWithNoNames() {
        XCTAssertEqual(
            MailboxesSupport.deadOutboxBannerText(messageCount: 1, accountNames: []),
            "1 message could not be sent — check SMTP settings on this account."
        )
    }

    func testPluralMessagesNameEveryDistinctAccount() {
        XCTAssertEqual(
            MailboxesSupport.deadOutboxBannerText(messageCount: 3, accountNames: ["Work", "Personal"]),
            "3 messages could not be sent — check SMTP settings on Work, Personal."
        )
    }

    func testDistinctAccountNamesKeepsFirstSeenOrderAndDropsUnknownIds() {
        let a = UUID(), b = UUID(), unknown = UUID()
        let accounts = [
            AccountResponse(
                id: a, name: "Work", imapHost: "h", imapPort: 993, imapUser: "u", smtpHost: nil,
                smtpPort: nil, smtpUser: nil, stateError: nil, capabilities: nil, createdAt: Date(),
                updatedAt: Date(), emoji: nil, folderOrder: nil, trashRetentionDays: nil,
                junkRetentionDays: nil
            ),
            AccountResponse(
                id: b, name: "Personal", imapHost: "h", imapPort: 993, imapUser: "u", smtpHost: nil,
                smtpPort: nil, smtpUser: nil, stateError: nil, capabilities: nil, createdAt: Date(),
                updatedAt: Date(), emoji: nil, folderOrder: nil, trashRetentionDays: nil,
                junkRetentionDays: nil
            ),
        ]
        let names = MailboxesSupport.distinctAccountNames(
            forAccountIds: [b, a, b, unknown], accounts: accounts
        )
        XCTAssertEqual(names, ["Personal", "Work"])
    }
}

final class MailboxesSupportShouldReloadTests: XCTestCase {

    func testReloadsOnFoldersChanged() {
        XCTAssertTrue(MailboxesSupport.shouldReload(for: [.foldersChanged]))
    }

    func testReloadsOnAccountsChanged() {
        XCTAssertTrue(MailboxesSupport.shouldReload(for: [.accountsChanged]))
    }

    func testReloadsOnResync() {
        XCTAssertTrue(MailboxesSupport.shouldReload(for: [.resync]))
    }

    func testIgnoresAnUnrelatedInvalidation() {
        XCTAssertFalse(MailboxesSupport.shouldReload(for: [.settingsChanged(category: "mail")]))
    }

    func testIgnoresAnEmptyBatch() {
        XCTAssertFalse(MailboxesSupport.shouldReload(for: []))
    }
}

final class MailboxesUIStateTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "MailboxesUIStateTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testCollapseStateRoundTripsAndTogglesIndependently() {
        let state = MailboxesUIState(defaults: makeDefaults())
        let accountKey = MailboxesUIState.accountKey(UUID())
        XCTAssertFalse(state.isCollapsed(accountKey))

        state.setCollapsed(true, forKey: accountKey)
        XCTAssertTrue(state.isCollapsed(accountKey))
        XCTAssertFalse(state.isCollapsed(MailboxesUIState.unifiedKey()))

        state.setCollapsed(false, forKey: accountKey)
        XCTAssertFalse(state.isCollapsed(accountKey))
    }

    func testTopVisibleRowIdRoundTripsAndDefaultsToNil() {
        let state = MailboxesUIState(defaults: makeDefaults())
        XCTAssertNil(state.topVisibleRowId())
        state.setTopVisibleRowId("unified:\(UUID())")
        XCTAssertNotNil(state.topVisibleRowId())
    }
}

final class MailboxesDiskCacheTests: XCTestCase {

    private func makeCache() -> MailboxesDiskCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MailboxesDiskCache(directory: directory)
    }

    func testLoadIsNilBeforeAnythingIsSaved() {
        XCTAssertNil(makeCache().load())
    }

    func testSavedSnapshotRoundTrips() {
        let cache = makeCache()
        let snapshot = MVMailboxesCacheSnapshot(
            unified: [
                MVMailboxesCachedUnified(
                    id: UUID(), name: "Everything", emoji: "📬", unreadCount: 4,
                    contributingAccountEmojis: ["✉️"]
                )
            ],
            accounts: [], savedAt: Date()
        )
        cache.save(snapshot)
        let loaded = cache.load()
        XCTAssertEqual(loaded?.unified, snapshot.unified)
        XCTAssertEqual(loaded?.accounts, snapshot.accounts)
        // `MVDateFormatting` round-trips through an ISO-8601 string, which keeps millisecond
        // precision, not `Date`'s own sub-millisecond one — exact equality on `savedAt` itself
        // would be asserting the encoder's precision, not this cache's behaviour.
        XCTAssertEqual(
            loaded?.savedAt.timeIntervalSince1970 ?? 0, snapshot.savedAt.timeIntervalSince1970, accuracy: 0.01)
    }

    func testASnapshotOlderThan24HoursIsTreatedAsMissing() {
        let cache = makeCache()
        let old = MVMailboxesCacheSnapshot(unified: [], accounts: [], savedAt: Date(timeIntervalSinceNow: -1))
        cache.save(old)
        let farInTheFuture = Date(timeIntervalSinceNow: 25 * 3600)
        XCTAssertNil(cache.load(now: farInTheFuture))
    }
}

final class MailboxesMostRecentUnifiedViewTests: XCTestCase {

    private func view(_ id: UUID, folderIds: [UUID]) -> (id: UUID, name: String, folderIds: Set<UUID>) {
        (id: id, name: "View \(id)", folderIds: Set(folderIds))
    }

    func testPrefersTheMostRecentlyOpenedViewAmongSeveralContainingTheFolder() {
        let folderId = UUID()
        let older = view(UUID(), folderIds: [folderId])
        let newer = view(UUID(), folderIds: [folderId])
        let recentRefs = [
            MVUnifiedViewRef(id: newer.id, name: newer.name), MVUnifiedViewRef(id: older.id, name: older.name),
        ]
        let resolved = MailboxesSupport.mostRecentUnifiedView(
            among: [older, newer], recentRefs: recentRefs, containingFolderId: folderId
        )
        XCTAssertEqual(resolved?.id, newer.id)
    }

    func testFallsBackToTheFirstMatchWhenNoRecentViewContainsTheFolder() {
        let folderId = UUID()
        let onlyMatch = view(UUID(), folderIds: [folderId])
        let unrelated = view(UUID(), folderIds: [UUID()])
        let resolved = MailboxesSupport.mostRecentUnifiedView(
            among: [onlyMatch], recentRefs: [MVUnifiedViewRef(id: unrelated.id, name: unrelated.name)],
            containingFolderId: folderId
        )
        XCTAssertEqual(resolved?.id, onlyMatch.id)
    }

    func testNilWhenNoKnownViewContainsTheFolder() {
        let resolved = MailboxesSupport.mostRecentUnifiedView(
            among: [view(UUID(), folderIds: [UUID()])], recentRefs: [], containingFolderId: UUID()
        )
        XCTAssertNil(resolved)
    }
}

final class MailboxesUnifiedMembershipTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "MailboxesUnifiedMembershipTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testUpdateThenLookupFindsTheContainingView() {
        let folderId = UUID()
        let viewId = UUID()
        let view = UnifiedFolderResponse(
            id: viewId, unifiedName: "Everything", emoji: nil,
            folders: [
                UnifiedFolderSource(
                    accountId: UUID(), accountName: "A", accountEmoji: nil, folderId: folderId,
                    imapName: "INBOX", specialUse: "inbox"
                )
            ],
            unreadCount: 0, totalCount: 0
        )
        let membership = MailboxesUnifiedMembership(recentViews: MVRecentViewRecord(defaults: makeDefaults()))
        membership.update(from: [view])
        XCTAssertEqual(membership.mostRecentUnifiedView(containingFolderId: folderId)?.id, viewId)
    }

    func testLookupIsNilBeforeAnyUpdate() {
        let membership = MailboxesUnifiedMembership(recentViews: MVRecentViewRecord(defaults: makeDefaults()))
        XCTAssertNil(membership.mostRecentUnifiedView(containingFolderId: UUID()))
    }
}

final class MailboxesSupportViewedRowKindTests: XCTestCase {

    private let accountId = UUID()
    private let folderId = UUID()
    private let viewId = UUID()

    func testFolderRowPushFromTheRootRecordsAFolderView() {
        let kind = MailboxesSupport.viewedRowKind(
            from: [], to: [.list(.folder(accountId: accountId, folderId: folderId), aroundMessageId: nil)])
        XCTAssertEqual(kind, .folder(accountId: accountId, folderId: folderId))
    }

    func testUnifiedRowPushFromTheRootRecordsAUnifiedView() {
        let kind = MailboxesSupport.viewedRowKind(
            from: [], to: [.list(.unified(viewId: viewId, name: "All"), aroundMessageId: nil)])
        XCTAssertEqual(kind, .unified(viewId: viewId, name: "All"))
    }

    func testResolverShapedDeepLinkRecordsNothing() {
        let scope = ListScope.folder(accountId: accountId, folderId: folderId)
        let messageId = UUID()
        let path: [Route] = [
            .list(scope, aroundMessageId: messageId),
            .reader(ReaderContext(source: .list(scope), messageId: messageId)),
        ]
        XCTAssertNil(MailboxesSupport.viewedRowKind(from: [], to: path))
    }

    func testAnchoredListAloneRecordsNothing() {
        let path: [Route] = [.list(.folder(accountId: accountId, folderId: folderId), aroundMessageId: UUID())]
        XCTAssertNil(MailboxesSupport.viewedRowKind(from: [], to: path))
    }

    func testPoppingBackToAListRecordsNothing() {
        let scope = ListScope.unified(viewId: viewId, name: "All")
        let list = Route.list(scope, aroundMessageId: nil)
        let reader = Route.reader(ReaderContext(source: .list(scope), messageId: UUID()))
        XCTAssertNil(MailboxesSupport.viewedRowKind(from: [list, reader], to: [list]))
    }

    func testNonListPushRecordsNothing() {
        XCTAssertNil(MailboxesSupport.viewedRowKind(from: [], to: [.settings]))
    }
}
