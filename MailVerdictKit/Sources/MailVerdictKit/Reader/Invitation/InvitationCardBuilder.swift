import Foundation

/// Everything the invitation card shows, and the card's own transient state.
public struct InvitationCardModel: Sendable, Equatable {
    /// The control whose request is in flight — it shows a spinner, and every card action is
    /// disabled until it settles.
    public enum BusyControl: Sendable, Equatable {
        case adding
        case responding(RespondRequest.Reply)
        case sendingAgain
        case confirming
        case retrying
    }

    public var invitation: Invitation
    public var calendars: [MVCalendar]
    public var identities: [IdentityResponse]
    /// Fetched only for `imported`/`updated` — its `partstat` and `ownReply` drive the RSVP row.
    public var event: EventInstance?
    /// The partstat just tapped, shown before the server answers: the backend writes PARTSTAT at
    /// once even while the reply itself is still being sent, so filling it early is honest.
    public var optimisticPartstat: MVPartstat?
    /// A note for the organizer, sent as `comment` with the next RSVP.
    public var comment: String
    /// "Always use this calendar for …" — sent as `link: true` with the next add.
    public var alwaysUseCalendar: Bool
    public var busy: BusyControl?

    public init(
        invitation: Invitation, calendars: [MVCalendar] = [], identities: [IdentityResponse] = [],
        event: EventInstance? = nil, optimisticPartstat: MVPartstat? = nil, comment: String = "",
        alwaysUseCalendar: Bool = false, busy: BusyControl? = nil
    ) {
        self.invitation = invitation
        self.calendars = calendars
        self.identities = identities
        self.event = event
        self.optimisticPartstat = optimisticPartstat
        self.comment = comment
        self.alwaysUseCalendar = alwaysUseCalendar
        self.busy = busy
    }

    public var calendar: MVCalendar? {
        calendars.first { $0.id == invitation.calendarId }
    }

    /// The web's own filter for where an invitation may be added.
    public var writableCalendars: [MVCalendar] {
        calendars.filter { !$0.readOnly }
    }

    /// A REQUEST that never named one of the account's own addresses — forwarded to it, so there
    /// is no attendee to reply as.
    public var isForwarded: Bool {
        invitation.ownAddress == nil && invitation.method == .request
    }

    public var isInCalendar: Bool {
        invitation.status == .imported || invitation.status == .updated
    }

    /// The identity an RSVP is sent from: the one attached to the event's own calendar.
    public var replyIdentity: IdentityResponse? {
        guard let event, let identityId = calendars.first(where: { $0.id == event.calendarId })?.identityId
        else { return nil }
        return identities.first { $0.id == identityId }
    }

    public var displayedPartstat: MVPartstat? {
        optimisticPartstat ?? event?.partstat
    }

    public var showsRSVP: Bool {
        isInCalendar && event?.partstat != nil
    }
}

/// The invitation card — port of the web's `invitation-card.tsx` and `rsvp-control.tsx`, rendered
/// as part of the page's HTML chrome. Every control is an `MVReaderLink.invitation` link; the
/// card is one block the page swaps whole when its state changes.
public enum InvitationCardBuilder {

    public static func slotId(messageId: UUID) -> String {
        "mv-invite-\(messageId.uuidString.lowercased())"
    }

    /// The placeholder every message carrying a calendar attachment starts with — the card is
    /// absent until its invitation loads, and stays absent on any error, as on the web.
    public static func emptySlot(messageId: UUID) -> String {
        #"<div class="mv-invite-slot" id="\#(slotId(messageId: messageId))"></div>"#
    }

    public static func html(for model: InvitationCardModel, timeZone: TimeZone = .current) -> String {
        let invitation = model.invitation
        let cancelled = invitation.status == .cancelled
        let bar = cancelled ? "var(--destructive)" : model.calendar.map(CalendarColor.resolve) ?? "var(--secondary)"
        var parts: [String] = [header(invitation, timeZone: timeZone)]
        parts.append(contentsOf: statusSections(model))
        let classes = cancelled ? "mv-invite mv-invite-cancelled" : "mv-invite"
        return #"<div class="mv-invite-slot" id="\#(slotId(messageId: invitation.messageId))">"#
            + #"<div class="\#(classes)" style="--bar: \#(bar)">"# + parts.joined() + "</div></div>"
    }

    // MARK: Header

    static func header(_ invitation: Invitation, timeZone: TimeZone) -> String {
        var rows = [
            #"<div class="mv-invite-title">\#(icon(.calendar))<span>\#(escape(invitation.summary.isEmpty ? "(no title)" : invitation.summary))</span></div>"#,
            line(timeText(invitation, timeZone: timeZone)),
        ]
        if let location = invitation.location, !location.isEmpty {
            rows.append(line(location))
        }
        if let organizer = invitation.organizer {
            rows.append(line("Invitation from \(organizer.cn.nonEmpty ?? organizer.email)"))
        }
        if !invitation.attendees.isEmpty {
            let count = invitation.attendees.count
            var text = "\(count) attendee\(count == 1 ? "" : "s")"
            if let own = invitation.ownAddress { text += " — you, as \(own)" }
            rows.append(#"<div class="mv-invite-line">\#(icon(.people))\#(escape(text))</div>"#)
        }
        return rows.joined()
    }

    static func timeText(_ invitation: Invitation, timeZone: TimeZone) -> String {
        eventTimeText(start: invitation.dtstart, end: invitation.dtend, allDay: invitation.allDay, timeZone: timeZone)
    }

    /// "EEE, MMM d · All day" or "EEE, MMM d · HH:mm–HH:mm" — the card's and the event details
    /// sheet's one time format, the web's own.
    public static func eventTimeText(start: Date, end: Date, allDay: Bool, timeZone: TimeZone = .current) -> String {
        let day = format(start, "EEE, MMM d", timeZone)
        if allDay { return "\(day) · All day" }
        return "\(day) · \(format(start, "HH:mm", timeZone))–\(format(end, "HH:mm", timeZone))"
    }

    // MARK: Status

    static func statusSections(_ model: InvitationCardModel) -> [String] {
        let invitation = model.invitation
        let id = invitation.messageId
        var sections: [String] = []

        if model.isInCalendar, let calendar = model.calendar {
            let lead = invitation.status == .updated ? "Updated in " : "Added to "
            let version = invitation.status == .updated ? " (version \(invitation.sequence))" : ""
            sections.append(
                #"<div class="mv-invite-status">\#(lead)<strong>\#(escape(calendar.displayName))</strong>\#(version)</div>"#
            )
        }
        if model.showsRSVP {
            sections.append(rsvp(model))
        }
        if model.isInCalendar {
            sections.append(detailsLink("Event Details", model))
        }

        switch invitation.status {
        case .unlinked where !model.isForwarded:
            sections.append(line("Not in a calendar yet"))
            sections.append(addToCalendar(model))
            let who = invitation.organizer?.email ?? "this sender"
            let on = model.alwaysUseCalendar ? " mv-on" : ""
            sections.append(
                link(
                    .invitation(messageId: id, action: .toggleAlwaysUse), model: model,
                    content: #"<span class="mv-switch\#(on)"></span>Always use this calendar for \#(escape(who))"#,
                    classes: "mv-toggle"))
        case .unlinked:
            sections.append(line("You were not invited directly, so a reply cannot be sent."))
            sections.append(addToCalendar(model))
        case .cancelled:
            sections.append(#"<div class="mv-invite-line mv-danger">This event was cancelled by the organizer.</div>"#)
        case .pendingReview:
            sections.append(pendingReview(model))
        case .unauthorized:
            sections.append(
                #"<div class="mv-invite-line mv-danger">This reply claims to be from an attendee but was not sent by them, so it was not applied.</div>"#
            )
            sections.append(detailsLink("View the Event", model))
        case .ignoredStale:
            sections.append(line("Outdated — a newer version of this invitation has already been applied."))
            sections.append(detailsLink("View the Event", model))
        case .failed:
            let target = model.calendar?.displayName ?? "the calendar"
            let reason = invitation.error.map { ": \($0)" } ?? "."
            sections.append(
                #"<div class="mv-invite-line mv-danger">\#(escape("Could not add to \(target)\(reason)"))</div>"#)
sections.append(
                button(
                    "Retry", icon: .retry, link: .invitation(messageId: id, action: .retry), model: model,
                    busyAs: .retrying, enabled: invitation.calendarId != nil))
        default:
            break
        }

        if invitation.method == .reply {
            let rows = invitation.attendees.map { attendee in
                #"<div class="mv-invite-attendee"><span>\#(escape(attendee.cn.nonEmpty ?? attendee.email))</span>"#
                    + #"<span class="mv-secondary">\#(escape(attendee.partstat.rawValue))</span></div>"#
            }
            sections.append(rows.joined())
            sections.append(detailsLink("Open Event", model))
        }
        return sections
    }

    static func addToCalendar(_ model: InvitationCardModel) -> String {
        button(
            "Add to Calendar…", icon: .calendarAdd,
            link: .invitation(messageId: model.invitation.messageId, action: .addToCalendar), model: model,
            busyAs: .adding, enabled: !model.writableCalendars.isEmpty)
    }

    static func pendingReview(_ model: InvitationCardModel) -> String {
        let invitation = model.invitation
        let isCancel = invitation.method == .cancel
        let summary = invitation.summary.isEmpty ? "this event" : invitation.summary
        let inCalendar = model.calendar.map { " in \($0.displayName)" } ?? ""
        let claimed = invitation.organizer.map { $0.cn.nonEmpty ?? $0.email } ?? "unknown"
        let consequence =
            isCancel
            ? "Accepting will cancel \"\(summary)\"\(inCalendar)."
            : "Accepting will change \"\(summary)\"\(inCalendar) to the details shown above."
        let confirm = button(
            isCancel ? "Confirm Cancellation" : "Accept Change", icon: nil,
            link: .invitation(messageId: invitation.messageId, action: .confirmChange), model: model,
            busyAs: .confirming, style: isCancel ? "mv-btn-destructive" : "mv-btn-primary")
        return #"<div class="mv-invite-review">"#
            + #"<p class="mv-amber">This message claims to \#(isCancel ? "cancel" : "update") an event already in your calendar. Nothing has changed yet — review it before accepting.</p>"#
            + #"<p class="mv-secondary">Claims to be from <strong>\#(escape(claimed))</strong><br>"#
            + #"Actually sent from <strong>\#(escape(invitation.fromAddr ?? "unknown"))</strong></p>"#
            + "<p>\(escape(consequence))</p>"
            + #"<div class="mv-invite-actions">\#(confirm)\#(detailsLink("View Current Event", model))</div></div>"#
    }

    // MARK: RSVP

    static func rsvp(_ model: InvitationCardModel) -> String {
        let id = model.invitation.messageId
        let identity = model.replyIdentity
        let options: [(RespondRequest.Reply, String, Icon)] = [
            (.accepted, "Accept", .check), (.tentative, "Tentative", .question), (.declined, "Decline", .cross),
        ]
        let buttons = options.map { reply, label, glyph in
            let filled = model.displayedPartstat?.rawValue == reply.rawValue
            return button(
                label, icon: glyph, link: .invitation(messageId: id, action: .respond(reply)), model: model,
                busyAs: .responding(reply), enabled: identity != nil,
                style: filled ? "mv-btn-primary" : "mv-btn-secondary")
        }
        var parts = [#"<div class="mv-rsvp">\#(buttons.joined())</div>"#]

        if identity == nil {
            parts.append(line("This calendar has no identity to reply from."))
        }
        switch model.event?.ownReply?.outboxStatus {
        case "pending", "processing":
            if let identity {
                parts.append(
                    #"<div class="mv-invite-line">\#(spinner)Sending reply from \#(escape(identity.address))…</div>"#)
            }
        case "unknown":
            parts.append(line("Reply status unknown"))
        case "sent":
            parts.append(line("Reply sent"))
        case "failed":
            parts.append(line("Retrying…"))
        case "dead":
            let verb = model.displayedPartstat == .accepted ? "accepted" : "responded"
            let reason = model.event?.ownReply?.error.map { ": \($0)" } ?? "."
            let again = button(
                "Send Again", icon: .retry, link: .invitation(messageId: id, action: .sendAgain), model: model,
                busyAs: .sendingAgain)
            parts.append(
                #"<div class="mv-invite-dead"><p>\#(escape("You \(verb), but the organizer has not been told. The reply could not be sent\(reason)"))</p>\#(again)</div>"#
            )
        default:
            break
        }

        let trimmed = model.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(#"<div class="mv-invite-note">“\#(escape(trimmed))”</div>"#)
        }
        parts.append(
            link(
                .invitation(messageId: id, action: .note), model: model,
                content: escape(trimmed.isEmpty ? "Add a note to the organizer" : "Edit note"), classes: "mv-link-small"
            ))
        return parts.joined()
    }

    // MARK: Pieces

    static func detailsLink(_ label: String, _ model: InvitationCardModel) -> String {
        guard model.invitation.objectId != nil else { return "" }
        return link(
            .invitation(messageId: model.invitation.messageId, action: .eventDetails), model: model,
            content: escape(label), classes: "mv-link-small", disableWhileBusy: false)
    }

    static func button(
        _ label: String, icon glyph: Icon?, link target: MVReaderLink, model: InvitationCardModel,
        busyAs control: InvitationCardModel.BusyControl, enabled: Bool = true, style: String = "mv-btn-secondary"
    ) -> String {
        let leading = model.busy == control ? spinner : glyph.map(icon) ?? ""
        return link(
            target, model: model, content: leading + "<span>\(escape(label))</span>", classes: "mv-btn \(style)",
            enabled: enabled)
    }

    /// An enabled control is a link; a disabled one is the same markup with no `href`, so a tap
    /// on it navigates nowhere.
    static func link(
        _ target: MVReaderLink, model: InvitationCardModel, content: String, classes: String,
        enabled: Bool = true, disableWhileBusy: Bool = true
    ) -> String {
        if !enabled || (disableWhileBusy && model.busy != nil) {
            return #"<span class="\#(classes) mv-disabled">\#(content)</span>"#
        }
        return #"<a class="\#(classes)" href="\#(target.url)">\#(content)</a>"#
    }

    static func line(_ text: String) -> String {
        #"<div class="mv-invite-line">\#(escape(text))</div>"#
    }

    static let spinner = #"<span class="mv-spinner"></span>"#

    private static func escape(_ text: String) -> String {
        PlainTextLinkifier.escapeHTML(text)
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    // MARK: Icons

    /// The card's glyphs, drawn as inline SVG since the page cannot use SF Symbols; shapes follow
    /// the matching symbols (`calendar`, `person.2`, `checkmark`, …).
    enum Icon {
        case calendar, people, check, question, cross, calendarAdd, retry
    }

    static func icon(_ icon: Icon) -> String {
        let path: String
        switch icon {
        case .calendar:
            path = #"<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>"#
        case .people:
            path =
                #"<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c0-3.6 2.9-6 6.5-6s6.5 2.4 6.5 6"/><circle cx="17" cy="9" r="2.5"/><path d="M17 14c2.8 0 4.5 1.9 4.5 5"/>"#
        case .check:
            path = #"<path d="M4.5 12.5l5 5 10-11"/>"#
        case .question:
            path = #"<path d="M9 9a3 3 0 1 1 4.5 2.6c-1 .6-1.5 1.3-1.5 2.4"/><circle cx="12" cy="18" r=".6"/>"#
        case .cross:
            path = #"<path d="M6 6l12 12M18 6L6 18"/>"#
        case .calendarAdd:
            path =
                #"<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4M12 13v5M9.5 15.5h5"/>"#
        case .retry:
            path = #"<path d="M20 12a8 8 0 1 1-2.3-5.7"/><path d="M20 4v5h-5"/>"#
        }
        return #"<svg class="mv-icon" viewBox="0 0 24 24" aria-hidden="true">\#(path)</svg>"#
    }

    /// The card's stylesheet, included once in every page's chrome styles.
    public static let css = """
        .mv-invite { margin: 4px 16px 12px; padding: 12px; border-radius: 12px; border-left: 4px solid var(--bar);
          background: var(--fill); display: flex; flex-direction: column; gap: 8px; font: -apple-system-subheadline; }
        .mv-invite-cancelled { background: color-mix(in srgb, var(--destructive) 5%, var(--fill)); }
        .mv-invite-title { display: flex; gap: 6px; align-items: center; font: -apple-system-headline; }
        .mv-invite-line, .mv-invite-status { color: var(--secondary); display: flex; gap: 6px; align-items: center; }
        .mv-invite-status { color: var(--label); display: block; }
        .mv-invite .mv-danger { color: var(--destructive); }
        .mv-invite .mv-amber { color: var(--amber-text); margin: 0; }
        .mv-invite p { margin: 0; }
        .mv-invite-review { border: 1px solid var(--amber-border); background: var(--amber-bg); border-radius: 10px;
          padding: 10px; display: flex; flex-direction: column; gap: 8px; }
        .mv-invite-dead { background: color-mix(in srgb, var(--destructive) 12%, transparent); color: var(--destructive);
          border-radius: 10px; padding: 10px; display: flex; flex-direction: column; gap: 8px; align-items: flex-start; }
        .mv-invite-actions { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
        .mv-invite-attendee { display: flex; justify-content: space-between; }
        .mv-invite-note { color: var(--secondary); font-style: italic; }
        .mv-rsvp { display: flex; gap: 6px; }
        .mv-rsvp .mv-btn { flex: 1; justify-content: center; }
        .mv-btn { display: inline-flex; align-items: center; gap: 6px; min-height: 36px; padding: 0 14px; border-radius: 18px;
          text-decoration: none; font: -apple-system-subheadline; font-weight: 600; box-sizing: border-box; }
        .mv-btn-primary { background: var(--tint); color: #fff; }
        .mv-btn-secondary { background: var(--fill-strong); color: var(--tint); }
        .mv-btn-destructive { background: var(--destructive); color: #fff; }
        .mv-disabled { opacity: 0.4; }
        .mv-link-small { color: var(--tint); text-decoration: none; font: -apple-system-footnote; }
        .mv-toggle { display: flex; gap: 8px; align-items: center; color: var(--secondary); text-decoration: none; }
        .mv-switch { width: 38px; height: 22px; border-radius: 11px; background: var(--fill-strong); position: relative; flex: none; }
        .mv-switch::after { content: ""; position: absolute; top: 2px; left: 2px; width: 18px; height: 18px; border-radius: 9px;
          background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.3); }
        .mv-switch.mv-on { background: #34c759; }
        .mv-switch.mv-on::after { left: 18px; }
        .mv-icon { width: 16px; height: 16px; flex: none; fill: none; stroke: currentColor; stroke-width: 2;
          stroke-linecap: round; stroke-linejoin: round; }
        .mv-spinner { width: 14px; height: 14px; border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent;
          animation: mv-spin .8s linear infinite; flex: none; }
        @keyframes mv-spin { to { transform: rotate(360deg); } }
        """
}

extension Optional where Wrapped == String {
    /// `cn || email` in the web's own terms — an empty string counts as absent.
    fileprivate var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
