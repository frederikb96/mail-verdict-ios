import Foundation

/// The list a selection was made in. A selection only ever describes that list: a predicate is
/// minted over one folder by construction, and an explicit pick is scoped the same way so it can
/// never silently apply to whatever list is on screen after the reader has moved on.
public struct MVSelectionScope: Hashable, Sendable {
    public let listScope: ListScope
    /// Grouped by conversation — a ticked row then stands for its whole conversation.
    public let threaded: Bool

    public init(listScope: ListScope, threaded: Bool) {
        self.listScope = listScope
        self.threaded = threaded
    }
}

public enum MVSelectionFilter: String, Sendable, Equatable {
    case all
    case unread
}

/// "Everything in this folder" (or everything unread), minted server-side
/// (`GET /accounts/{id}/messages/selection`). A message mirrored after `snapshotAt` is outside
/// the selection however it later reads, so the count shown and the set acted on agree.
public struct MVSelectionPredicate: Equatable, Sendable {
    public let accountId: UUID
    public let folderId: UUID
    public let filter: MVSelectionFilter
    public let snapshotAt: Date
    /// The server's count at snapshot time, before exclusions.
    public let count: Int

    public init(accountId: UUID, folderId: UUID, filter: MVSelectionFilter, snapshotAt: Date, count: Int) {
        self.accountId = accountId
        self.folderId = folderId
        self.filter = filter
        self.snapshotAt = snapshotAt
        self.count = count
    }
}

/// The fields selection logic reads off a row.
public struct MVSelectableRow: Equatable, Sendable {
    public let id: UUID
    public let accountId: UUID
    public let folderId: UUID
    public let isSeen: Bool
    public let mirroredAt: Date?

    public init(id: UUID, accountId: UUID, folderId: UUID, isSeen: Bool, mirroredAt: Date?) {
        self.id = id
        self.accountId = accountId
        self.folderId = folderId
        self.isSeen = isSeen
        self.mirroredAt = mirroredAt
    }

    public init(_ summary: MessageSummary) {
        self.init(
            id: summary.id, accountId: summary.accountId, folderId: summary.folderId,
            isSeen: summary.isSeen, mirroredAt: summary.mirroredAt
        )
    }
}

/// A predicate plus two explicit id maps layered on top of it (port of the web's
/// `lib/selection.ts`). With no predicate, `included` is the whole selection. With one, a row
/// matching it is selected unless named in `excluded`, and a row outside it (mail that arrived
/// after the snapshot) only if named in `included`. Membership is re-derived per row, so rows
/// scrolling in and out of the loaded window never lose anything.
///
/// Both maps record each id's account at the moment it was ticked — building the bulk requests
/// later never re-derives it from a list that may have dropped the row by then.
public struct MVSelection: Equatable, Sendable {
    public private(set) var predicate: MVSelectionPredicate?
    public private(set) var included: [UUID: UUID]
    public private(set) var excluded: [UUID: UUID]
    /// `nil` only for `.empty`, which has nothing to be scoped to.
    public private(set) var scope: MVSelectionScope?

    public static let empty = MVSelection(predicate: nil, included: [:], excluded: [:], scope: nil)

    private init(
        predicate: MVSelectionPredicate?, included: [UUID: UUID], excluded: [UUID: UUID],
        scope: MVSelectionScope?
    ) {
        self.predicate = predicate
        self.included = included
        self.excluded = excluded
        self.scope = scope
    }

    /// Select-all over a folder: the predicate alone, nothing explicit on top.
    public static func all(_ predicate: MVSelectionPredicate, in scope: MVSelectionScope) -> MVSelection {
        MVSelection(predicate: predicate, included: [:], excluded: [:], scope: scope)
    }

    /// An explicit pick of every given row — select-all in a unified view, where there is no
    /// single folder to mint a predicate over.
    public static func explicit(_ rows: [MVSelectableRow], in scope: MVSelectionScope) -> MVSelection {
        var included: [UUID: UUID] = [:]
        for row in rows { included[row.id] = row.accountId }
        return MVSelection(predicate: nil, included: included, excluded: [:], scope: scope)
    }

    /// This selection as it applies to `scope`: itself, or empty once it was made in a
    /// different list. The one place that decides whether a selection still describes the
    /// screen; every reader and every gesture goes through it.
    public func scoped(to scope: MVSelectionScope) -> MVSelection {
        guard let own = self.scope, own != scope else { return self }
        return .empty
    }

    public static func matches(_ predicate: MVSelectionPredicate, _ row: MVSelectableRow) -> Bool {
        guard row.folderId == predicate.folderId else { return false }
        if predicate.filter == .unread && row.isSeen { return false }
        guard let mirroredAt = row.mirroredAt else { return false }
        return mirroredAt <= predicate.snapshotAt
    }

    public func isSelected(_ row: MVSelectableRow) -> Bool {
        guard let predicate else { return included[row.id] != nil }
        if Self.matches(predicate, row) { return excluded[row.id] == nil }
        return included[row.id] != nil
    }

    /// Derived rather than tracked, so it can never drift from the membership rule.
    public var count: Int {
        guard let predicate else { return included.count }
        return predicate.count - excluded.count + included.count
    }

    public var isEmpty: Bool { count == 0 }

    /// A tap on a row in select mode. A selection made in another list is discarded first, so
    /// the toggle always starts from one that describes what is on screen.
    public func toggling(_ row: MVSelectableRow, in scope: MVSelectionScope) -> MVSelection {
        var next = scoped(to: scope)
        next.setChecked(row, !next.isSelected(row))
        next.scope = scope
        return next
    }

    /// Sets one row the way whichever mode is active expresses it.
    private mutating func setChecked(_ row: MVSelectableRow, _ checked: Bool) {
        if let predicate, Self.matches(predicate, row) {
            if checked { excluded[row.id] = nil } else { excluded[row.id] = row.accountId }
        } else {
            if checked { included[row.id] = row.accountId } else { included[row.id] = nil }
        }
    }
}

/// The select-mode title and scope line — the count in the words the UX design uses, including
/// what "all" means once rows are conversations.
public enum MVSelectionText {
    public static func title(for selection: MVSelection, threaded: Bool) -> String {
        let count = selection.count
        if let predicate = selection.predicate {
            let noun = predicate.filter == .unread ? "Unread" : (count == 1 ? "Message" : "Messages")
            return "All \(count.formatted()) \(noun)"
        }
        if count == 0 { return "Select Messages" }
        if threaded {
            return "\(count.formatted()) \(count == 1 ? "Conversation" : "Conversations") Selected"
        }
        return "\(count.formatted()) Selected"
    }

    /// A predicate matches raw messages even while rows are conversations, so a threaded
    /// select-all acts on every message of every matching conversation — said out loud rather
    /// than left for someone about to archive thousands of messages to infer.
    public static func scopeNote(for selection: MVSelection, threaded: Bool) -> String? {
        guard selection.predicate != nil, threaded else { return nil }
        return "Every message in every matching conversation"
    }
}
