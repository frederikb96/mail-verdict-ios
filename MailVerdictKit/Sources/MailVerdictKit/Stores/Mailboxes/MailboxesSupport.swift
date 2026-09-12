import Foundation

/// Inbox, Drafts, Sent, Archive, Junk, Trash, in that fixed order — the web's own
/// `SPECIAL_USE_ORDER` (`app-sidebar.tsx`).
private let folderLeadOrder = ["inbox", "drafts", "sent", "archive", "junk", "trash"]

/// The two shapes `MailboxesSupport.leadOrderedFolders` sorts — `/folder-order`'s
/// `FolderOrderItem` and the plain `/folders` list's `FolderResponse` — conformed here rather
/// than alongside the models themselves, which the CLAUDE.md layering keeps behaviour-free.
public protocol MVFolderLeadSortable {
    var specialUse: String? { get }
    var imapName: String { get }
}

extension FolderOrderItem: MVFolderLeadSortable {}
extension FolderResponse: MVFolderLeadSortable {}

public enum MailboxesSupport {

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
        var seen = Set<UUID>()
        var names: [String] = []
        for id in accountIds {
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            if let account = accounts.first(where: { $0.id == id }) {
                names.append(account.name)
            }
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

    /// Whether a batch of live invalidations means this screen's data is stale: `folder.changed`,
    /// `account.changed` and a resync, plus every `mail.*` event (folded into
    /// `folderSynced`/`mailNew` etc), all of which leave folder and unread counts stale the same
    /// way `foldersChanged` does.
    public static func shouldReload(for invalidations: [MVLiveInvalidation]) -> Bool {
        invalidations.contains {
            switch $0 {
            case .resync, .foldersChanged, .accountsChanged, .folderSynced, .mailNew, .mailUpdated, .mailDeleted:
                return true
            default:
                return false
            }
        }
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
