import XCTest

@testable import MailVerdictKit

final class InvitationCardBuilderTests: XCTestCase {

    private let calendarId = UUID()
    private let identityId = UUID()
    private let messageId = UUID()
    private let objectId = UUID()

    private func invitation(
        status: MVInvitationStatus, method: Invitation.Method = .request, ownAddress: String? = "me@example.org",
        calendarId: UUID? = nil
    ) -> Invitation {
        Invitation(
            messageId: messageId, method: method, status: status, uid: "u", summary: "Kickoff",
            dtstart: Date(timeIntervalSince1970: 1_704_099_600), dtend: Date(timeIntervalSince1970: 1_704_105_000),
            allDay: false, location: nil, organizer: EventOrganizer(email: "org@example.org", cn: nil), attendees: [],
            ownAddress: ownAddress, sequence: 0, calendarId: calendarId, calendarName: nil, objectId: objectId,
            error: nil, ownReply: nil, fromAddr: "spoof@lookalike.example")
    }

    private func calendar(identity: UUID?, color: String = "#22c55e") -> MVCalendar {
        MVCalendar(
            id: calendarId, davAccountId: UUID(), davAccountName: "a", displayName: "Personal", color: color,
            colorOverride: nil, isVisible: true, isEnabled: true, readOnly: false, identityId: identity, intake: .none,
            holdsEvents: true, syncError: nil, initialSyncDone: true, totalCount: 0, defaultReminderMinutes: nil,
            remindersEnabled: nil, resolvedDefaultReminderMinutes: nil)
    }

    private func event(partstat: MVPartstat?) -> EventInstance {
        EventInstance(
            objectId: objectId, recurrenceId: nil, calendarId: calendarId, uid: "u", summary: "Kickoff",
            dtstart: Date(), dtend: Date(), tz: nil, allDay: false, location: nil, description: nil,
            status: .confirmed, sequence: 0, rrule: nil, organizer: nil, partstat: partstat, isRecurring: false,
            isException: false, pending: false, syncError: nil, ownReply: nil, sourceMessageId: nil, readOnly: false,
            transparency: .opaque)
    }

    private var identity: IdentityResponse {
        IdentityResponse(
            id: identityId, accountId: UUID(), address: "me@example.org", displayName: nil, isDefault: true,
            createdAt: Date())
    }

    private func href(_ action: MVInvitationLinkAction) -> String {
        #"href="\#(MVReaderLink.invitation(messageId: messageId, action: action).url)""#
    }

    private func importedModel(identity hasIdentity: Bool) -> InvitationCardModel {
        InvitationCardModel(
            invitation: invitation(status: .imported, calendarId: calendarId),
            calendars: [calendar(identity: hasIdentity ? identityId : nil)], identities: [identity],
            event: event(partstat: .needsAction))
    }

    func testForwardedInvitationOffersNoAlwaysUse() {
        let html = InvitationCardBuilder.html(
            for: InvitationCardModel(
                invitation: invitation(status: .unlinked, ownAddress: nil), calendars: [calendar(identity: nil)]))
        XCTAssertTrue(html.contains("You were not invited directly"))
        XCTAssertFalse(html.contains(href(.toggleAlwaysUse)))
        XCTAssertTrue(html.contains(href(.addToCalendar)))
    }

    func testDirectInvitationOffersAlwaysUse() {
        let html = InvitationCardBuilder.html(
            for: InvitationCardModel(invitation: invitation(status: .unlinked), calendars: [calendar(identity: nil)]))
        XCTAssertTrue(html.contains(href(.toggleAlwaysUse)))
    }

    func testRetryIsOnlyPressableWithTheInvitationsOwnCalendar() {
        let without = InvitationCardBuilder.html(for: InvitationCardModel(invitation: invitation(status: .failed)))
        XCTAssertFalse(without.contains(href(.retry)))
        let with = InvitationCardBuilder.html(
            for: InvitationCardModel(invitation: invitation(status: .failed, calendarId: calendarId)))
        XCTAssertTrue(with.contains(href(.retry)))
    }

    func testRSVPIsDisabledWithoutAReplyIdentity() {
        let html = InvitationCardBuilder.html(for: importedModel(identity: false))
        XCTAssertFalse(html.contains(href(.respond(.accepted))))
        XCTAssertTrue(html.contains("This calendar has no identity to reply from."))
        XCTAssertTrue(
            InvitationCardBuilder.html(for: importedModel(identity: true)).contains(href(.respond(.accepted))))
    }

    func testTappedAnswerShowsFilledBeforeTheServerAnswers() {
        var model = importedModel(identity: true)
        model.optimisticPartstat = .tentative
        let html = InvitationCardBuilder.html(for: model)
        XCTAssertTrue(html.contains(#"class="mv-btn mv-btn-primary" \#(href(.respond(.tentative)))"#))
        XCTAssertTrue(html.contains(#"class="mv-btn mv-btn-secondary" \#(href(.respond(.accepted)))"#))
    }

    func testWhileBusyOnlyEventDetailsStaysPressable() {
        var model = importedModel(identity: true)
        model.busy = .responding(.accepted)
        let html = InvitationCardBuilder.html(for: model)
        XCTAssertFalse(html.contains(href(.respond(.declined))))
        XCTAssertFalse(html.contains(href(.note)))
        XCTAssertTrue(html.contains(href(.eventDetails)))
    }

    func testReviewCardNamesTheClaimedAndTheActualSender() {
        let html = InvitationCardBuilder.html(
            for: InvitationCardModel(invitation: invitation(status: .pendingReview, method: .cancel)))
        XCTAssertTrue(html.contains("Confirm Cancellation"))
        XCTAssertTrue(html.contains("org@example.org"))
        XCTAssertTrue(html.contains("spoof@lookalike.example"))
        XCTAssertTrue(html.contains(href(.confirmChange)))
    }

    func testTimesReadLikeTheWeb() {
        let utc = TimeZone(identifier: "UTC")!
        var timed = invitation(status: .imported)
        XCTAssertEqual(InvitationCardBuilder.timeText(timed, timeZone: utc), "Mon, Jan 1 · 09:00–10:30")
        timed = Invitation(
            messageId: messageId, method: .request, status: .imported, uid: "u", summary: "", dtstart: timed.dtstart,
            dtend: timed.dtend, allDay: true, location: nil, organizer: nil, ownAddress: nil, sequence: 0,
            calendarId: nil, calendarName: nil, objectId: nil, error: nil, ownReply: nil, fromAddr: nil)
        XCTAssertEqual(InvitationCardBuilder.timeText(timed, timeZone: utc), "Mon, Jan 1 · All day")
    }

    /// Expected values computed with the web's own `paletteColorForCalendarId`, so both clients
    /// agree on an uncoloured calendar's colour.
    func testUncolouredCalendarGetsTheSameColourAsTheWeb() {
        XCTAssertEqual(
            CalendarColor.paletteColor(forCalendarId: UUID(uuidString: "5B1D7E0A-3C2F-4B8E-9F10-2A6C4D8E0301")!),
            "#3b82f6")
        XCTAssertEqual(
            CalendarColor.paletteColor(forCalendarId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!),
            "#ef4444")
        XCTAssertEqual(
            CalendarColor.paletteColor(forCalendarId: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!),
            "#22c55e")
    }

    func testNonHexServerColourNeverReachesTheMarkup() {
        let resolved = CalendarColor.resolve(calendar(identity: nil, color: "red;background:url(x)"))
        XCTAssertTrue(resolved.hasPrefix("#"))
        XCTAssertFalse(resolved.contains("url"))
    }
}
