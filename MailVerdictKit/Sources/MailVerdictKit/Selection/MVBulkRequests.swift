import Foundation

/// One `POST /accounts/{accountId}/messages/bulk-action` — the API is scoped to one account per
/// request, so an explicit selection spanning a unified view's accounts becomes several.
public struct MVBulkRequestPlan: Equatable, Sendable {
    public let accountId: UUID
    public let request: BulkActionRequest

    public init(accountId: UUID, request: BulkActionRequest) {
        self.accountId = accountId
        self.request = request
    }
}

public enum MVBulkRequestBuilder {

    /// The requests a bulk action on `selection` sends.
    ///
    /// A predicate is single-account by construction and goes out as a scope, with any rows
    /// ticked on top of it as explicit ids alongside. An explicit selection is grouped by the
    /// account each id was ticked under, and — grouped by conversation — asks the server to
    /// expand every id to its whole conversation, since that is what a ticked row stood for.
    ///
    /// `targetFolderId` resolves the destination per account: a unified view's "same" folder
    /// has a different id in each account. An account it cannot resolve for a `move` is left
    /// out and reported in `skippedAccountIds` rather than sent without a target.
    public static func plans(
        for selection: MVSelection, action: MVBulkAction, targetFolderId: (UUID) -> UUID? = { _ in nil }
    ) -> (plans: [MVBulkRequestPlan], skippedAccountIds: [UUID]) {
        var requests: [(accountId: UUID, ids: [UUID]?, scope: BulkActionScope?, expand: Bool)] = []

        if let predicate = selection.predicate {
            let scope = BulkActionScope(
                folderId: predicate.folderId, filter: predicate.filter.rawValue,
                excludeIds: sortedIds(selection.excluded.keys), snapshotAt: predicate.snapshotAt
            )
            let extra = sortedIds(selection.included.keys)
            requests.append((predicate.accountId, extra.isEmpty ? nil : extra, scope, false))
        } else {
            var grouped: [UUID: [UUID]] = [:]
            for (id, accountId) in selection.included { grouped[accountId, default: []].append(id) }
            let expand = selection.scope?.threaded == true
            for accountId in sortedIds(grouped.keys) {
                requests.append((accountId, sortedIds(grouped[accountId] ?? []), nil, expand))
            }
        }

        var plans: [MVBulkRequestPlan] = []
        var skipped: [UUID] = []
        for entry in requests {
            let target = action == .move ? targetFolderId(entry.accountId) : nil
            if action == .move && target == nil {
                skipped.append(entry.accountId)
                continue
            }
            let request = BulkActionRequest(
                action: action, targetFolderId: target, ids: entry.ids, scope: entry.scope,
                expandThreads: entry.expand
            )
            plans.append(MVBulkRequestPlan(accountId: entry.accountId, request: request))
        }
        return (plans, skipped)
    }

    /// Undo for an explicit bulk move out of a folder: every message back to the folder it came
    /// from, one request per account and folder — a unified-view undo spans accounts the same
    /// way the action it reverses did.
    public static func undoPlans(for sources: [MVMovedMessage]) -> [MVBulkRequestPlan] {
        var grouped: [UUID: [UUID: [UUID]]] = [:]
        for source in sources {
            grouped[source.accountId, default: [:]][source.originalFolderId, default: []].append(source.messageId)
        }
        var plans: [MVBulkRequestPlan] = []
        for accountId in sortedIds(grouped.keys) {
            let byFolder = grouped[accountId] ?? [:]
            for folderId in sortedIds(byFolder.keys) {
                let request = BulkActionRequest(
                    action: .move, targetFolderId: folderId, ids: sortedIds(byFolder[folderId] ?? [])
                )
                plans.append(MVBulkRequestPlan(accountId: accountId, request: request))
            }
        }
        return plans
    }

    /// A batch over a predicate is resolved server-side and cannot be undone — there is nothing
    /// client-side to enumerate a source folder from — so these confirm with a count instead.
    public static func needsConfirmation(_ selection: MVSelection, action: MVBulkAction) -> Bool {
        guard selection.predicate != nil else { return false }
        return [.move, .trash, .spam, .expunge].contains(action)
    }

    private static func sortedIds<S: Sequence>(_ ids: S) -> [UUID] where S.Element == UUID {
        ids.sorted { $0.uuidString < $1.uuidString }
    }
}

/// One message a move carried out of a folder — what an Undo has to move back.
public struct MVMovedMessage: Equatable, Sendable {
    public let messageId: UUID
    public let accountId: UUID
    public let originalFolderId: UUID

    public init(messageId: UUID, accountId: UUID, originalFolderId: UUID) {
        self.messageId = messageId
        self.accountId = accountId
        self.originalFolderId = originalFolderId
    }
}
