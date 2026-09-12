import Foundation

/// What one SSE record means for the app's stores — never what a store should *do* about it; the
/// UX design's event table drives this mapping, and every effect described in that table's "iOS
/// effect" column (a bounded window refresh, a badge recompute, a toast) is a store's own job
/// against the rows below, not this type's.
public enum MVLiveInvalidation: Sendable, Equatable {
    /// Every store refetches; a list store does a bounded window refresh rather than starting
    /// over, per the scrolling skill's own rule against ever losing scroll position.
    case resync
    case mailNew(accountId: UUID?, folderId: UUID?, messageId: UUID?)
    case mailUpdated(accountId: UUID?, folderId: UUID?, messageId: UUID?, changed: [String])
    case mailDeleted(accountId: UUID?, folderId: UUID?, messageId: UUID?)
    case verdictIssued(accountId: UUID?, messageId: UUID?, isSpam: Bool?)
    case folderSynced(accountId: UUID?, folderId: UUID?)
    case foldersChanged
    case alertsChanged
    case notificationsChanged
    case accountsChanged
    case outboxUpdated(MVOutboxEventPayload)
    case settingsChanged(category: String?)
    case identitiesChanged(accountId: UUID?)
    /// `outbox.updated` carrying `itip: "reply"`, or `calendar.object` — the reader's invitation
    /// card and its event-details sheet are what this refreshes, never a mail toast or list
    /// refresh (the addendum's own amendment to the base event table).
    case invitationOrEventChanged
    /// Every event name this app has no effect for — `pipeline.*`, and every `calendar.*` /
    /// `contact.*` besides `calendar.object`. Carrying the name rather than discarding it keeps
    /// this a decision a test can see, not a silent drop.
    case ignored(SSEEventName)
    /// An event name the vendored snapshot does not know about yet — never thrown away, the same
    /// reasoning as `.ignored`, but distinguished because it means the contract has drifted
    /// rather than that this app chose not to act.
    case unknown(String)
}

/// `outbox.updated`'s own payload — mirrored by hand against `server.py::_outbox_event_payload`,
/// since SSE payload shapes are untyped dicts server-side (systems design §5.02's own note on
/// what stays manual).
public struct MVOutboxEventPayload: Sendable, Equatable {
    public let id: UUID?
    public let changed: [String]
    public let status: String?
    public let kind: String?
    /// `"reply"` when this row is a calendar RSVP rather than a mail send — not sent by every
    /// server yet; see `LiveEventHub`'s own mapping note.
    public let itip: String?

    public init(id: UUID?, changed: [String] = [], status: String? = nil, kind: String? = nil, itip: String? = nil) {
        self.id = id
        self.changed = changed
        self.status = status
        self.kind = kind
        self.itip = itip
    }
}
