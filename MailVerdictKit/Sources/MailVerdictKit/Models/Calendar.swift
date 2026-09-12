import Foundation

// Mirrors mail_verdict/api/schemas.py's calendar and invitation shapes this app ports (the
// reader's invitation card, a read-only event-details sheet, and the writable-calendar picker
// for importing a new invitation). Calendar management screens are out of scope.

public enum MVPartstat: String, Sendable, Equatable, CaseIterable, Codable {
    case needsAction = "needs-action"
    case accepted
    case declined
    case tentative
}

public enum MVAttendeeRole: String, Sendable, Equatable, CaseIterable, Codable {
    case chair
    case reqParticipant = "req-participant"
    case optParticipant = "opt-participant"
    case nonParticipant = "non-participant"
}

public enum MVEventStatus: String, Sendable, Equatable, CaseIterable, Codable {
    case confirmed
    case tentative
    case cancelled
}

public enum MVEventTransparency: String, Sendable, Equatable, CaseIterable, Codable {
    case opaque
    case transparent
}

/// The `Invitation.status` values the backend's `calendar/intake.py` can write. `unknown(_:)` is
/// not a value the backend sends today — it exists so a status this client has not been taught
/// about yet decodes as "nothing to show" (the card's own rule for `ignored`/`pending`, see
/// `calendar/intake.py`'s own note on `InvitationStatus`) rather than failing the whole message.
public enum MVInvitationStatus: Sendable, Equatable, Codable {
    case imported
    case updated
    case unlinked
    case cancelled
    case ignoredStale
    case failed
    case ignored
    case unauthorized
    case pending
    case pendingReview
    case unknown(String)

    private static let wireValues: [String: MVInvitationStatus] = [
        "imported": .imported, "updated": .updated, "unlinked": .unlinked,
        "cancelled": .cancelled, "ignored_stale": .ignoredStale, "failed": .failed,
        "ignored": .ignored, "unauthorized": .unauthorized, "pending": .pending,
        "pending_review": .pendingReview,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.wireValues[raw] ?? .unknown(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let raw =
            Self.wireValues.first(where: { $0.value == self })?.key
            ?? { if case .unknown(let value) = self { return value } else { return "unknown" } }()
        try container.encode(raw)
    }
}

public struct EventAttendee: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "EventAttendeeOut"
    public enum ContractKeys: String, CodingKey, CaseIterable { case email, cn, partstat, role }
    public typealias CodingKeys = ContractKeys

    public let email: String
    public let cn: String?
    public let partstat: MVPartstat
    public let role: MVAttendeeRole

    public init(email: String, cn: String?, partstat: MVPartstat, role: MVAttendeeRole) {
        self.email = email
        self.cn = cn
        self.partstat = partstat
        self.role = role
    }
}

public struct EventOrganizer: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "EventOrganizerOut"
    public enum ContractKeys: String, CodingKey, CaseIterable { case email, cn }
    public typealias CodingKeys = ContractKeys

    public let email: String
    public let cn: String?

    public init(email: String, cn: String?) {
        self.email = email
        self.cn = cn
    }
}

/// The last outbox row this identity's respond produced for an event — `nil` until an RSVP has
/// ever been sent.
public struct OwnReply: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "OwnReplyOut"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case partstat, outboxId = "outbox_id", outboxStatus = "outbox_status", error,
            updatedAt = "updated_at"
    }
    public typealias CodingKeys = ContractKeys

    public let partstat: MVPartstat
    public let outboxId: UUID
    public let outboxStatus: String
    public let error: String?
    public let updatedAt: Date

    public init(partstat: MVPartstat, outboxId: UUID, outboxStatus: String, error: String?, updatedAt: Date) {
        self.partstat = partstat
        self.outboxId = outboxId
        self.outboxStatus = outboxStatus
        self.error = error
        self.updatedAt = updatedAt
    }
}

/// One DISPLAY alarm — exactly one of `offsetMinutes`/`at` is set, iCalendar's own sign
/// convention kept (negative offset = before the start).
public struct EventReminder: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "EventReminder"
    public enum ContractKeys: String, CodingKey, CaseIterable { case offsetMinutes = "offset_minutes", at }
    public typealias CodingKeys = ContractKeys

    public let offsetMinutes: Int?
    public let at: Date?

    public init(offsetMinutes: Int? = nil, at: Date? = nil) {
        self.offsetMinutes = offsetMinutes
        self.at = at
    }
}

/// One event instance — the master, or one named occurrence (`recurrenceId` set).
public struct EventInstance: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "EventInstanceOut"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case objectId = "object_id", recurrenceId = "recurrence_id", calendarId = "calendar_id",
            uid, summary, dtstart, dtend, tz, allDay = "all_day", location, description, status,
            sequence, rrule, organizer, attendees, partstat, isRecurring = "is_recurring",
            isException = "is_exception", pending, syncError = "sync_error",
            ownReply = "own_reply", sourceMessageId = "source_message_id", readOnly = "read_only",
            reminders, transparency
    }
    public typealias CodingKeys = ContractKeys

    /// `objectId` alone, not paired with `recurrenceId` — a recurring event's occurrences all
    /// share one `objectId`, but nothing in this app lists two `EventInstance`s side by side
    /// (the reader's card shows one event at a time), so the collision never arises in practice.
    public var id: UUID { objectId }
    public let objectId: UUID
    public let recurrenceId: String?
    public let calendarId: UUID
    public let uid: String
    public let summary: String
    public let dtstart: Date
    public let dtend: Date
    public let tz: String?
    public let allDay: Bool
    public let location: String?
    public let description: String?
    public let status: MVEventStatus
    public let sequence: Int
    public let rrule: String?
    public let organizer: EventOrganizer?
    public let attendees: [EventAttendee]
    public let partstat: MVPartstat?
    public let isRecurring: Bool
    public let isException: Bool
    public let pending: Bool
    public let syncError: String?
    public let ownReply: OwnReply?
    public let sourceMessageId: UUID?
    public let readOnly: Bool
    public let reminders: [EventReminder]
    public let transparency: MVEventTransparency

    public init(
        objectId: UUID, recurrenceId: String?, calendarId: UUID, uid: String, summary: String,
        dtstart: Date, dtend: Date, tz: String?, allDay: Bool, location: String?,
        description: String?, status: MVEventStatus, sequence: Int, rrule: String?,
        organizer: EventOrganizer?, attendees: [EventAttendee] = [], partstat: MVPartstat?,
        isRecurring: Bool, isException: Bool, pending: Bool, syncError: String?,
        ownReply: OwnReply?, sourceMessageId: UUID?, readOnly: Bool,
        reminders: [EventReminder] = [], transparency: MVEventTransparency
    ) {
        self.objectId = objectId
        self.recurrenceId = recurrenceId
        self.calendarId = calendarId
        self.uid = uid
        self.summary = summary
        self.dtstart = dtstart
        self.dtend = dtend
        self.tz = tz
        self.allDay = allDay
        self.location = location
        self.description = description
        self.status = status
        self.sequence = sequence
        self.rrule = rrule
        self.organizer = organizer
        self.attendees = attendees
        self.partstat = partstat
        self.isRecurring = isRecurring
        self.isException = isException
        self.pending = pending
        self.syncError = syncError
        self.ownReply = ownReply
        self.sourceMessageId = sourceMessageId
        self.readOnly = readOnly
        self.reminders = reminders
        self.transparency = transparency
    }
}

public struct RespondRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "RespondRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case identityId = "identity_id", partstat, comment, recurrenceId = "recurrence_id"
    }
    public typealias CodingKeys = ContractKeys

    /// Only these three are a legal RSVP — `.needsAction` is never sent, only ever received.
    public enum Reply: String, Sendable, Equatable, Codable {
        case accepted
        case declined
        case tentative
    }

    public let identityId: UUID
    public let partstat: Reply
    public let comment: String?
    public let recurrenceId: String?

    public init(identityId: UUID, partstat: Reply, comment: String? = nil, recurrenceId: String? = nil) {
        self.identityId = identityId
        self.partstat = partstat
        self.comment = comment
        self.recurrenceId = recurrenceId
    }
}

public struct ImportInvitationRequest: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "ImportInvitationRequest"
    public enum ContractKeys: String, CodingKey, CaseIterable { case calendarId = "calendar_id", link }
    public typealias CodingKeys = ContractKeys

    public let calendarId: UUID?
    @MVDefaulted<MVDefaultFalse> public var link: Bool

    public init(calendarId: UUID? = nil, link: Bool = false) {
        self.calendarId = calendarId
        self.link = link
    }
}

/// The parsed invitation, its intake status, and the calendar it ended up in (or would, or did
/// before something went wrong) — `GET /api/calendar/invitations/{messageId}`.
public struct Invitation: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "InvitationResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case messageId = "message_id", method, status, uid, summary, dtstart, dtend,
            allDay = "all_day", location, organizer, attendees, ownAddress = "own_address",
            sequence, calendarId = "calendar_id", calendarName = "calendar_name",
            objectId = "object_id", error, ownReply = "own_reply", fromAddr = "from_addr"
    }
    public typealias CodingKeys = ContractKeys

    public enum Method: String, Sendable, Equatable, Codable {
        case request = "REQUEST"
        case reply = "REPLY"
        case cancel = "CANCEL"
        case counter = "COUNTER"
    }

    public let messageId: UUID
    public let method: Method
    public let status: MVInvitationStatus
    public let uid: String
    public let summary: String
    public let dtstart: Date
    public let dtend: Date
    public let allDay: Bool
    public let location: String?
    public let organizer: EventOrganizer?
    public let attendees: [EventAttendee]
    public let ownAddress: String?
    public let sequence: Int
    public let calendarId: UUID?
    public let calendarName: String?
    public let objectId: UUID?
    public let error: String?
    public let ownReply: OwnReply?
    /// The message's own envelope sender — shown next to `organizer` on a `pendingReview` card so
    /// a forged ORGANIZER line is obvious at a glance. A hint for a person to judge, not a check
    /// the backend enforces.
    public let fromAddr: String?

    public init(
        messageId: UUID, method: Method, status: MVInvitationStatus, uid: String, summary: String,
        dtstart: Date, dtend: Date, allDay: Bool, location: String?, organizer: EventOrganizer?,
        attendees: [EventAttendee] = [], ownAddress: String?, sequence: Int, calendarId: UUID?,
        calendarName: String?, objectId: UUID?, error: String?, ownReply: OwnReply?,
        fromAddr: String?
    ) {
        self.messageId = messageId
        self.method = method
        self.status = status
        self.uid = uid
        self.summary = summary
        self.dtstart = dtstart
        self.dtend = dtend
        self.allDay = allDay
        self.location = location
        self.organizer = organizer
        self.attendees = attendees
        self.ownAddress = ownAddress
        self.sequence = sequence
        self.calendarId = calendarId
        self.calendarName = calendarName
        self.objectId = objectId
        self.error = error
        self.ownReply = ownReply
        self.fromAddr = fromAddr
    }
}

public enum MVCalendarIntakeState: String, Sendable, Equatable, CaseIterable, Codable {
    case none
    case importOnly = "import"
    case importAndLink = "import_and_link"
}

/// A calendar, merged with its preferences — `GET /api/calendars`. Named `MVCalendar` rather
/// than `Calendar`: this package imports `Foundation`, whose own `Calendar` (the date-calculation
/// type) would otherwise collide with a bare `Calendar` in every file that also needs a date
/// computation.
public struct MVCalendar: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "CalendarResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, davAccountId = "dav_account_id", davAccountName = "dav_account_name",
            displayName = "display_name", color, colorOverride = "color_override",
            isVisible = "is_visible", isEnabled = "is_enabled", readOnly = "read_only",
            identityId = "identity_id", intake, supportedComponents = "supported_components",
            holdsEvents = "holds_events", syncError = "sync_error",
            initialSyncDone = "initial_sync_done", totalCount = "total_count",
            defaultReminderMinutes = "default_reminder_minutes",
            remindersEnabled = "reminders_enabled",
            resolvedDefaultReminderMinutes = "resolved_default_reminder_minutes"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let davAccountId: UUID
    public let davAccountName: String
    public let displayName: String
    public let color: String
    public let colorOverride: String?
    public let isVisible: Bool
    public let isEnabled: Bool
    public let readOnly: Bool
    public let identityId: UUID?
    public let intake: MVCalendarIntakeState
    public let supportedComponents: [String]
    public let holdsEvents: Bool
    public let syncError: String?
    public let initialSyncDone: Bool
    public let totalCount: Int
    public let defaultReminderMinutes: Int?
    public let remindersEnabled: Bool?
    public let resolvedDefaultReminderMinutes: Int?

    public init(
        id: UUID, davAccountId: UUID, davAccountName: String, displayName: String, color: String,
        colorOverride: String?, isVisible: Bool, isEnabled: Bool, readOnly: Bool,
        identityId: UUID?, intake: MVCalendarIntakeState, supportedComponents: [String] = [],
        holdsEvents: Bool, syncError: String?, initialSyncDone: Bool, totalCount: Int,
        defaultReminderMinutes: Int?, remindersEnabled: Bool?,
        resolvedDefaultReminderMinutes: Int?
    ) {
        self.id = id
        self.davAccountId = davAccountId
        self.davAccountName = davAccountName
        self.displayName = displayName
        self.color = color
        self.colorOverride = colorOverride
        self.isVisible = isVisible
        self.isEnabled = isEnabled
        self.readOnly = readOnly
        self.identityId = identityId
        self.intake = intake
        self.supportedComponents = supportedComponents
        self.holdsEvents = holdsEvents
        self.syncError = syncError
        self.initialSyncDone = initialSyncDone
        self.totalCount = totalCount
        self.defaultReminderMinutes = defaultReminderMinutes
        self.remindersEnabled = remindersEnabled
        self.resolvedDefaultReminderMinutes = resolvedDefaultReminderMinutes
    }
}
