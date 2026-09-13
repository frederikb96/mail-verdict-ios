import Foundation

/// Everything the shared `MailRowView` (`MailVerdict/Common/MailRowView.swift`) needs to render
/// one row — built once here so the list and search screens never diverge on it. A store builds
/// one of these per row; the view itself holds no logic.
public struct MVMailRowData: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let isUnread: Bool
    public let senderName: String
    /// Already formatted (`MVDateFormat.relativeDate`) — the view never does date arithmetic.
    public let dateText: String
    public let pendingSync: Bool
    public let subject: String?
    /// `> 1` shows the thread-count capsule; `nil`/`1` shows nothing (threaded mode only).
    public let threadCount: Int?
    public let isAnswered: Bool
    public let hasAttachments: Bool
    public let verdictIsSpam: Bool
    public let isStarred: Bool
    /// `nil` for an ordinary row, where `line4` alone wraps across both preview lines — a search
    /// result sets this to "To: a, b, c +N more" (`formatRecipientList`) as its own single line,
    /// with `line4` then limited to one line for the snippet underneath it.
    public let line3: String?
    /// The snippet, parsed for `**bold**` spans (`parseBoldMarkers`) — plain prose for an
    /// ordinary row, the matched terms bold for a search result.
    public let line4: [MVTextSegment]
    /// The identity (an email address, almost always) `avatarColorHex`/`getInitials` key off.
    public let avatarIdentity: String
    /// A store derives this from `ContactPhotoIndexEntry.avatarSource`, read from a photo index
    /// fetched once and cached rather than looked up per row.
    public let avatarPhoto: MVAvatarPhotoSource?
    /// Set on a unified-view row — the contributing account's emoji, shown as a badge at the
    /// avatar's bottom-trailing corner.
    public let unifiedAccountEmoji: String?
    /// Set when more than one account can appear in the same list (search, unified) — shown as
    /// a trailing chip.
    public let accountChip: String?

    public init(
        id: UUID, isUnread: Bool, senderName: String, dateText: String, pendingSync: Bool = false,
        subject: String?, threadCount: Int? = nil, isAnswered: Bool = false,
        hasAttachments: Bool = false, verdictIsSpam: Bool = false, isStarred: Bool = false,
        line3: String?, line4: [MVTextSegment], avatarIdentity: String,
        avatarPhoto: MVAvatarPhotoSource? = nil, unifiedAccountEmoji: String? = nil,
        accountChip: String? = nil
    ) {
        self.id = id
        self.isUnread = isUnread
        self.senderName = senderName
        self.dateText = dateText
        self.pendingSync = pendingSync
        self.subject = subject
        self.threadCount = threadCount
        self.isAnswered = isAnswered
        self.hasAttachments = hasAttachments
        self.verdictIsSpam = verdictIsSpam
        self.isStarred = isStarred
        self.line3 = line3
        self.line4 = line4
        self.avatarIdentity = avatarIdentity
        self.avatarPhoto = avatarPhoto
        self.unifiedAccountEmoji = unifiedAccountEmoji
        self.accountChip = accountChip
    }

    /// The ordinary (non-search) shape: the snippet alone, wrapping across both preview lines.
    /// `snippetMarksMatches` is set for a quick-filter hit, whose snippet carries the server's
    /// `**bold**` markers around the matched terms.
    public static func plain(
        id: UUID, isUnread: Bool, senderName: String, dateText: String, pendingSync: Bool = false,
        subject: String?, threadCount: Int? = nil, isAnswered: Bool = false,
        hasAttachments: Bool = false, verdictIsSpam: Bool = false, isStarred: Bool = false,
        snippet: String?, snippetMarksMatches: Bool = false, avatarIdentity: String,
        avatarPhoto: MVAvatarPhotoSource? = nil, unifiedAccountEmoji: String? = nil
    ) -> MVMailRowData {
        let line4: [MVTextSegment]
        if let snippet {
            line4 = snippetMarksMatches ? parseBoldMarkers(snippet) : [MVTextSegment(text: snippet, isBold: false)]
        } else {
            line4 = []
        }
        return MVMailRowData(
            id: id, isUnread: isUnread, senderName: senderName, dateText: dateText,
            pendingSync: pendingSync, subject: subject, threadCount: threadCount,
            isAnswered: isAnswered, hasAttachments: hasAttachments, verdictIsSpam: verdictIsSpam,
            isStarred: isStarred, line3: nil, line4: line4,
            avatarIdentity: avatarIdentity, avatarPhoto: avatarPhoto,
            unifiedAccountEmoji: unifiedAccountEmoji
        )
    }
}
