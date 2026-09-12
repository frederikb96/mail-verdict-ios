import Foundation

/// One message's invitation card: loading it, adding the event, and replying — the web's
/// `useInvitation`, `useImportInvitation` and `RsvpControl` behaviour.
///
/// Every mutating call returns the server's error text, or `nil` on success; the caller shows it.
/// After any request settles the card re-reads its state, so what it shows is always the server's.
@MainActor
public final class InvitationStore {
    public let messageId: UUID
    public private(set) var model: InvitationCardModel?

    /// Called whenever `model` changes — the page swaps the card's block for `slotHTML`.
    public var onChange: (@MainActor () -> Void)?

    private let api: MVApiClient
    private let lookups: ReaderLookups

    public init(messageId: UUID, api: MVApiClient, lookups: ReaderLookups) {
        self.messageId = messageId
        self.api = api
        self.lookups = lookups
    }

    public var slotHTML: String {
        model.map { InvitationCardBuilder.html(for: $0) } ?? InvitationCardBuilder.emptySlot(messageId: messageId)
    }

    /// Loads or refreshes the card. A failure leaves whatever was shown — nothing, before the
    /// first success, as on the web.
    public func load() async {
        guard let invitation = try? await api.getInvitation(messageId: messageId) else { return }
        let calendars = await lookups.calendars()
        let identities = await lookups.identities()
        var event: EventInstance?
        if invitation.status == .imported || invitation.status == .updated, let objectId = invitation.objectId {
            event = try? await api.getEvent(objectId: objectId)
        }
        var next = model ?? InvitationCardModel(invitation: invitation)
        next.invitation = invitation
        next.calendars = calendars
        next.identities = identities
        next.event = event
        if next.busy == nil { next.optimisticPartstat = nil }
        update(next)
    }

    /// "Add to Calendar…" with the calendar picked from the native menu.
    public func add(to calendarId: UUID) async -> String? {
        guard let model else { return nil }
        let link = model.alwaysUseCalendar && !model.isForwarded
        return await importInvitation(ImportInvitationRequest(calendarId: calendarId, link: link), busy: .adding)
    }

    /// Confirm Cancellation / Accept Change on a card awaiting review.
    public func confirmChange() async -> String? {
        await importInvitation(ImportInvitationRequest(), busy: .confirming)
    }

    public func retry() async -> String? {
        guard let calendarId = model?.invitation.calendarId else { return nil }
        return await importInvitation(ImportInvitationRequest(calendarId: calendarId), busy: .retrying)
    }

    public func respond(_ reply: RespondRequest.Reply) async -> String? {
        await send(reply, busy: .responding(reply))
    }

    /// Resends the current answer after a reply could not be delivered.
    public func sendAgain() async -> String? {
        let current = model?.displayedPartstat.flatMap { RespondRequest.Reply(rawValue: $0.rawValue) } ?? .accepted
        return await send(current, busy: .sendingAgain)
    }

    public func toggleAlwaysUse() {
        guard var next = model else { return }
        next.alwaysUseCalendar.toggle()
        update(next)
    }

    public func setComment(_ comment: String) {
        guard var next = model else { return }
        next.comment = comment
        update(next)
    }

    // MARK: Requests

    private func importInvitation(_ request: ImportInvitationRequest, busy: InvitationCardModel.BusyControl) async
        -> String?
    {
        guard begin(busy) else { return nil }
        var failure: String?
        do {
            let result = try await api.importInvitation(messageId: messageId, request)
            model?.invitation = result
        } catch {
            failure = error.mvUserMessage
        }
        finish()
        await load()
        return failure
    }

    private func send(_ reply: RespondRequest.Reply, busy: InvitationCardModel.BusyControl) async -> String? {
        guard let current = model, let event = current.event, let identity = current.replyIdentity,
            begin(busy)
        else { return nil }
        model?.optimisticPartstat = MVPartstat(rawValue: reply.rawValue)
        onChange?()

        let comment = current.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = RespondRequest(
            identityId: identity.id, partstat: reply, comment: comment.isEmpty ? nil : comment,
            recurrenceId: event.recurrenceId)
        var failure: String?
        do {
            model?.event = try await api.respondToEvent(objectId: event.objectId, request)
            model?.comment = ""
        } catch {
            failure = error.mvUserMessage
        }
        model?.optimisticPartstat = nil
        finish()
        await load()
        return failure
    }

    private func begin(_ busy: InvitationCardModel.BusyControl) -> Bool {
        guard var next = model, next.busy == nil else { return false }
        next.busy = busy
        update(next)
        return true
    }

    private func finish() {
        guard var next = model else { return }
        next.busy = nil
        update(next)
    }

    private func update(_ next: InvitationCardModel) {
        guard next != model else { return }
        model = next
        onChange?()
    }
}
