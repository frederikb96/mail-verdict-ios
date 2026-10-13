import Foundation

/// Inbox, Drafts, Sent, Archive, Junk, Trash, in that fixed order — the web's own
/// `SPECIAL_USE_ORDER` (`app-sidebar.tsx`).
private let folderLeadOrder = ["inbox", "drafts", "sent", "archive", "junk", "trash"]

/// The two shapes `MailboxesSupport.leadOrderedFolders` sorts — `/folder-order`'s
/// `FolderOrderItem` and the plain `/folders` list's `FolderResponse` — conformed here rather
/// than alongside the models themselves, which the package layering keeps behaviour-free.
public protocol MVFolderLeadSortable {
    var specialUse: String? { get }
    var imapName: String { get }
}

extension FolderOrderItem: MVFolderLeadSortable {}
extension FolderResponse: MVFolderLeadSortable {}

/// What one batch of live invalidations asks the Mailboxes screen to re-read. Plans from
/// successive batches merge, so a reload that is already running costs at most one more.
public struct MailboxesReloadPlan: Equatable, Sendable {
    /// Accounts, unified views, the dead outbox, the badge and every account's sync status and
    /// folders.
    public var everything = false
    /// Folder rows of `countAccountIds` (every account when `countsForAllAccounts`) and the
    /// unified rows.
    public var counts = false
    public var countAccountIds: Set<UUID> = []
    public var countsForAllAccounts = false
    public var badge = false
    public var deadOutbox = false

    public init(
        everything: Bool = false, counts: Bool = false, countAccountIds: Set<UUID> = [],
        countsForAllAccounts: Bool = false, badge: Bool = false, deadOutbox: Bool = false
    ) {
        self.everything = everything
        self.counts = counts
        self.countAccountIds = countAccountIds
        self.countsForAllAccounts = countsForAllAccounts
        self.badge = badge
        self.deadOutbox = deadOutbox
    }

    public static let all = MailboxesReloadPlan(everything: true)

    public var isEmpty: Bool { self == MailboxesReloadPlan() }

    public mutating func merge(_ other: MailboxesReloadPlan) {
        everything = everything || other.everything
        counts = counts || other.counts
        countAccountIds.formUnion(other.countAccountIds)
        countsForAllAccounts = countsForAllAccounts || other.countsForAllAccounts
        badge = badge || other.badge
        deadOutbox = deadOutbox || other.deadOutbox
    }
}

public enum MailboxesSupport {

    /// The row a Mailboxes tap opened, read off the navigation change it caused: a row's
    /// `NavigationLink` is the only push that lands a bare list, anchored on no message, directly
    /// on the root. `MVMessagePlaceResolver` always anchors its list on a message and pushes the
    /// reader with it, so a deep link or notification tap never counts as picking a view.
    public static func viewedRowKind(from oldPath: [Route], to newPath: [Route]) -> MailboxesRowKind? {
        guard oldPath.isEmpty, newPath.count == 1, case .list(let scope, aroundMessageId: .none) = newPath[0]
        else { return nil }
        switch scope {
        case .folder(let accountId, let folderId): return .folder(accountId: accountId, folderId: folderId)
        case .unified(let viewId, let name): return .unified(viewId: viewId, name: name)
        }
    }

    /// Visible folders in the order `GET /folder-order` resolved, with INBOX forced to lead
    /// regardless of a saved order — the web's own `orderedFolders` does this unconditionally
    /// because a saved order rarely moves INBOX far from the top, and it buries INBOX when there
    /// is no saved order to move it at all.
    ///
    /// When no order was ever saved, the backend's own fallback is plain alphabetical with no
    /// other special-use treatment at all (`get_folder_order` in `folder_management.py`) —
    /// `hasCustomOrder` (a non-empty `AccountResponse.folderOrder`) tells that case apart from a
    /// real saved order, so it gets the web's full lead sequence (`leadOrderedFolders`) instead of
    /// just the INBOX promotion, without overriding a folder the account holder genuinely dragged
    /// elsewhere.
    public static func orderFolders(_ items: [FolderOrderItem], hasCustomOrder: Bool) -> [FolderOrderItem] {
        let visible = items.filter(\.isVisible)
        guard hasCustomOrder else { return leadOrderedFolders(visible) }
        guard let inboxIndex = visible.firstIndex(where: { $0.specialUse == "inbox" }), inboxIndex > 0
        else { return visible }
        var reordered = visible
        let inbox = reordered.remove(at: inboxIndex)
        reordered.insert(inbox, at: 0)
        return reordered
    }

    /// Port of the web's `sortFolders` (`app-sidebar.tsx`): every special-use folder leads, in
    /// `folderLeadOrder`'s sequence (an unrecognised `specialUse` sorts after the six named ones,
    /// same as the web's `indexOf` fallback of 99); everything else follows, alphabetically by
    /// IMAP name. Reused wherever a folder list carries no saved-order concept at all — the plain
    /// `/folders` list (`PushFolderScope.groups`) — as well as `orderFolders`'s own no-saved-order
    /// case above.
    public static func leadOrderedFolders<F: MVFolderLeadSortable>(_ folders: [F]) -> [F] {
        let special = folders.filter { $0.specialUse != nil }
            .sorted { leadIndex($0) < leadIndex($1) }
        let regular = folders.filter { $0.specialUse == nil }
            .sorted { $0.imapName.localizedStandardCompare($1.imapName) == .orderedAscending }
        return special + regular
    }

    private static func leadIndex<F: MVFolderLeadSortable>(_ folder: F) -> Int {
        folder.specialUse.flatMap { folderLeadOrder.firstIndex(of: $0) } ?? Int.max
    }

    /// The badge a folder row shows — Drafts never carries an unread state, so the total stands in
    /// for it. Port of the web's `getFolderBadgeCount`.
    public static func folderBadgeCount(specialUse: String?, unreadCount: Int, totalCount: Int) -> Int {
        specialUse == "drafts" ? totalCount : unreadCount
    }

    /// Which accounts feed a merged unified folder, in first-seen order, deduplicated — port of
    /// the web's `getContributingAccounts`.
    public static func contributingAccounts(
        for view: UnifiedFolderResponse, accounts: [AccountResponse]
    ) -> [AccountResponse] {
        var seen = Set<UUID>()
        var result: [AccountResponse] = []
        for source in view.folders {
            guard !seen.contains(source.accountId) else { continue }
            seen.insert(source.accountId)
            if let account = accounts.first(where: { $0.id == source.accountId }) {
                result.append(account)
            }
        }
        return result
    }

    /// Distinct account names among a set of dead-outbox rows, in first-seen order — port of the
    /// web's `Array.from(new Set(dead.map(...))).map(...).filter(...)` in `outbox-dead-banner.tsx`,
    /// silently skipping an id with no matching account the same way.
    public static func distinctAccountNames(
        forAccountIds accountIds: [UUID], accounts: [AccountResponse]
    ) -> [String] {
        distinctAccountNames(forAccountIds: accountIds) { id in accounts.first { $0.id == id }?.name }
    }

    /// The same for a caller that holds names rather than whole accounts.
    public static func distinctAccountNames(
        forAccountIds accountIds: [UUID], name: (UUID) -> String?
    ) -> [String] {
        var seen = Set<UUID>()
        var names: [String] = []
        for id in accountIds {
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            if let found = name(id) { names.append(found) }
        }
        return names
    }

    /// The dead-outbox banner text, or `nil` when there is nothing to show — port of
    /// `outbox-dead-banner.tsx`. Pass an empty `accountNames` from a scope that is already known
    /// to be one account, where naming "this account" reads better than repeating its name.
    public static func deadOutboxBannerText(messageCount: Int, accountNames: [String]) -> String? {
        guard messageCount > 0 else { return nil }
        let plural = messageCount > 1 ? "s" : ""
        let target = accountNames.isEmpty ? "this account" : accountNames.joined(separator: ", ")
        return "\(messageCount) message\(plural) could not be sent — check SMTP settings on \(target)."
    }

    /// What a batch of live invalidations makes stale on this screen, and nothing more. A mail
    /// event moves counts only: the folder rows of its account and the unified rows. `accountOfFolder`
    /// names the account a folder-only event (`folder.synced`) belongs to; a folder it does not know
    /// widens the reload to every account.
    public static func reloadPlan(
        for invalidations: [MVLiveInvalidation], accountOfFolder: (UUID) -> UUID?
    ) -> MailboxesReloadPlan {
        var plan = MailboxesReloadPlan()
        func countsChanged(accountId: UUID?, folderId: UUID?) {
            plan.counts = true
            if let account = accountId ?? folderId.flatMap(accountOfFolder) {
                plan.countAccountIds.insert(account)
            } else {
                plan.countsForAllAccounts = true
            }
        }
        for invalidation in invalidations {
            switch invalidation {
            case .resync, .accountsChanged, .foldersChanged:
                plan.everything = true
            case .mailNew(let accountId, let folderId, _), .mailDeleted(let accountId, let folderId, _),
                .folderSynced(let accountId, let folderId):
                countsChanged(accountId: accountId, folderId: folderId)
            case .mailUpdated(let accountId, let folderId, _, let changed):
                if MVLiveInvalidation.messageUpdateMovesCounts(changed: changed) {
                    countsChanged(accountId: accountId, folderId: folderId)
                }
            case .alertsChanged:
                plan.badge = true
            case .outboxUpdated:
                plan.deadOutbox = true
            default:
                continue
            }
        }
        return plan
    }

    /// Among every unified view containing this folder, the one opened most recently — falling
    /// back to the first one found when none of the recently opened views match, which is what
    /// keeps this total rather than `nil` the moment the relevant view has aged out of the
    /// 5-entry recency list `MVRecentViewRecord` keeps. A free function rather than a method on
    /// `MailboxesStore`: it touches no actor state, and `MailboxesUnifiedMembership` (the
    /// `MVUnifiedViewMembershipLookup` conformer, which must stay off the main actor to satisfy
    /// that protocol's own `Sendable` requirement) needs this exact logic too.
    public static func mostRecentUnifiedView(
        among views: [(id: UUID, name: String, folderIds: Set<UUID>)], recentRefs: [MVUnifiedViewRef],
        containingFolderId folderId: UUID
    ) -> MVUnifiedViewRef? {
        let candidates = views.filter { $0.folderIds.contains(folderId) }
        guard !candidates.isEmpty else { return nil }
        for ref in recentRefs {
            if let match = candidates.first(where: { $0.id == ref.id }) {
                return MVUnifiedViewRef(id: match.id, name: match.name)
            }
        }
        guard let first = candidates.first else { return nil }
        return MVUnifiedViewRef(id: first.id, name: first.name)
    }
}
