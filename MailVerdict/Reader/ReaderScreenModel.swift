import MailVerdictKit
import Observation
import UIKit

/// The reader screen's view state — which sheet or dialog is up — and the glue from a tapped
/// control to the session. Everything with rules in it lives in `ReaderSession`.
@Observable
@MainActor
final class ReaderScreenModel {
    struct AddressChoice: Identifiable {
        let id = UUID()
        let field: MVReaderLink.AddressField
        let address: String
        let line: [String]
    }

    struct MoveRequest: Identifiable {
        let id = UUID()
        let accountId: UUID
        let currentFolderId: UUID
    }

    struct EventDetailsRequest: Identifiable {
        let id: UUID
        let calendars: [MVCalendar]
    }

    struct CalendarChoice: Identifiable {
        let id = UUID()
        let messageId: UUID
        let calendars: [MVCalendar]
    }

    let session: ReaderSession
    @ObservationIgnored weak var pager: ReaderViewController?

    var addressChoice: AddressChoice?
    var moveRequest: MoveRequest?
    var eventDetails: EventDetailsRequest?
    var calendarChoice: CalendarChoice?
    var noteMessageId: UUID?
    var noteText = ""
    var quickLookURL: URL?
    var confirmingDeleteForever = false
    /// A tapped `tel:`/`sms:` link, or a detected phone number, awaiting the user's confirmation
    /// before it leaves the app.
    var confirmingPhoneHandoff: URL?
    /// Debug screenshots only: the Options menu's content in a sheet, since a system menu
    /// cannot be opened without a touch.
    var optionsPreview = false

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private let close: @MainActor () -> Void

    init(
        context: ReaderContext, environment: AppEnvironment, connection: AppEnvironment.Connection, theme: MVCanvas,
        close: @escaping @MainActor () -> Void
    ) {
        self.environment = environment
        self.close = close
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        session = ReaderSession(
            context: context, api: connection.apiClient, placeResolver: connection.placeResolver, theme: theme,
            cacheDirectory: caches ?? FileManager.default.temporaryDirectory)
        // Held weakly by the hub, so the subscription ends with the reader.
        _ = connection.liveEventHub.subscribe(session)
        session.onToast = { [weak environment] toast in
            environment?.toasts.show(toast)
        }
        session.onCurrentRemoved = { [weak self] removal in
            switch removal {
            case .advance(_, let direction): self?.pager?.slideToCurrent(from: direction)
            case .exhausted: self?.close()
            }
        }
    }

    var primary: MessageDetail? { session.currentPrimary }

    var senderEmail: String { extractEmail(primary?.fromAddr) }

    var senderDomain: String {
        String(senderEmail.split(separator: "@").dropFirst().first ?? "")
    }

    func didDisappear() {
        session.cleanUp()
    }

    // MARK: Bars

    func page(_ direction: MVAutoAdvanceDirection) {
        pager?.turn(direction)
    }

    func archive() { apply(session.remove(with: .archive)) }
    func delete() { apply(session.remove(with: .trash)) }
    func deleteForever() { apply(session.remove(with: .expunge)) }

    private func apply(_ outcome: ReaderActionOutcome) {
        switch outcome {
        case .stay: break
        case .advance(_, let direction): pager?.slideToCurrent(from: direction)
        case .close: close()
        }
    }

    // MARK: Options

    func perform(_ action: MVMessageUIAction) {
        guard let message = primary else { return }
        switch action {
        case .reply, .replyAll, .forward:
            environment.presentedCompose = session.composeIntent(for: action)
        case .confirmVerdict, .correctVerdict:
            Task { await session.sendVerdictFeedback(confirming: action == .confirmVerdict) }
        case .markRead, .markUnread:
            Task { await session.setRead(action == .markRead) }
        case .star, .unstar:
            Task { await session.setStarred(action == .star) }
        case .moveTo:
            moveRequest = MoveRequest(accountId: message.accountId, currentFolderId: message.folderId)
        case .moveToJunk:
            apply(session.remove(with: .spam))
        case .notJunk:
            apply(session.remove(with: .notSpam))
        case .archive:
            archive()
        case .findInMessage:
            pager?.presentFind()
        case .loadImagesOnce:
            Task { await session.loadImagesOnce(messageId: message.id) }
        case .alwaysLoadFromSender:
            Task { await session.alwaysLoadImages(messageId: message.id, from: .sender) }
        case .alwaysLoadFromDomain:
            Task { await session.alwaysLoadImages(messageId: message.id, from: .domain) }
        case .darkBackground, .lightBackground:
            session.toggleCanvas(messageId: message.id)
        case .shareMessageFile:
            Task {
                do {
                    let url = try await session.rawMessageFile()
                    pager?.presentShare(url)
                } catch {
                    showError("Could not download the message file", error)
                }
            }
        case .showInFolder:
            Task {
                if let route = await session.showInFolderRoute() {
                    environment.navigationPath.append(route)
                }
            }
        case .delete:
            delete()
        case .deleteForever:
            confirmingDeleteForever = true
        }
    }

    func move(to target: MVMoveTarget, accountId: UUID) {
        guard let folderId = target.folderId(forAccount: accountId) else { return }
        Task { await session.move(to: folderId) }
    }

    // MARK: Page controls

    func handle(_ navigation: MVReaderNavigation) {
        switch navigation {
        case .control(let link):
            handle(link)
        case .web(let url):
            pager?.presentSafari(url)
        case .mailto(let url):
            if let link = parseMailto(url.absoluteString) {
                environment.presentedCompose = ComposeIntent(kind: .mailto(link))
            }
        case .phone(let url):
            confirmingPhoneHandoff = url
        case .allow, .anchor, .ignore:
            break
        }
    }

    var phoneHandoffIsMessage: Bool { confirmingPhoneHandoff?.scheme?.lowercased() == "sms" }

    func confirmPhoneHandoff() {
        guard let url = confirmingPhoneHandoff else { return }
        confirmingPhoneHandoff = nil
        UIApplication.shared.open(url)
    }

    private func handle(_ link: MVReaderLink) {
        switch link {
        case .address(let messageId, let field, let index):
            if let found = session.addresses(messageId: messageId, field: field, index: index) {
                addressChoice = AddressChoice(field: field, address: found.address, line: found.line)
            }
        case .attachment(let messageId, let attachmentId):
            openAttachment(messageId: messageId, attachmentId: attachmentId)
        case .shareAttachment(let messageId, let attachmentId):
            shareAttachment(messageId: messageId, attachmentId: attachmentId)
        case .images(let messageId, let choice):
            Task {
                switch choice {
                case .once: await session.loadImagesOnce(messageId: messageId)
                case .sender, .domain: await session.alwaysLoadImages(messageId: messageId, from: choice)
                }
            }
        case .draft(let messageId):
            environment.presentedCompose = ComposeIntent(kind: .draft(messageId: messageId))
        case .retry:
            session.retry(session.currentRowId)
        case .invitation(let messageId, let action):
            handleInvitation(action, messageId: messageId)
        }
    }

    func openAttachment(messageId: UUID, attachmentId: UUID) {
        Task {
            do {
                quickLookURL = try await session.attachmentFile(messageId: messageId, attachmentId: attachmentId)
            } catch {
                showError("Could not open the attachment", error)
            }
        }
    }

    func shareAttachment(messageId: UUID, attachmentId: UUID) {
        Task {
            do {
                let url = try await session.attachmentFile(messageId: messageId, attachmentId: attachmentId)
                pager?.presentShare(url)
            } catch {
                showError("Could not download the attachment", error)
            }
        }
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        environment.toasts.show(MVToast(variant: .info, message: "Copied \(text)", duration: 2))
    }

    func compose(to address: String) {
        environment.presentedCompose = ComposeIntent(kind: .mailto(MailtoLink(to: [address])))
    }

    // MARK: Invitation card

    private func handleInvitation(_ action: MVInvitationLinkAction, messageId: UUID) {
        guard let store = session.invitationStore(for: messageId), let model = store.model else { return }
        switch action {
        case .addToCalendar:
            calendarChoice = CalendarChoice(messageId: messageId, calendars: model.writableCalendars)
        case .toggleAlwaysUse:
            store.toggleAlwaysUse()
        case .respond(let reply):
            run { await store.respond(reply) }
        case .sendAgain:
            run { await store.sendAgain() }
        case .confirmChange:
            run { await store.confirmChange() }
        case .retry:
            run { await store.retry() }
        case .note:
            noteText = model.comment
            noteMessageId = messageId
        case .eventDetails:
            if let objectId = model.invitation.objectId {
                eventDetails = EventDetailsRequest(id: objectId, calendars: model.calendars)
            }
        }
    }

    func addInvitation(_ choice: CalendarChoice, to calendarId: UUID) {
        guard let store = session.invitationStore(for: choice.messageId) else { return }
        run { await store.add(to: calendarId) }
    }

    func saveNote() {
        guard let messageId = noteMessageId else { return }
        session.invitationStore(for: messageId)?.setComment(noteText)
        noteMessageId = nil
    }

    private func run(_ request: @escaping @MainActor () async -> String?) {
        Task {
            if let failure = await request() {
                environment.toasts.show(MVToast(variant: .error, message: failure, duration: 0))
            }
        }
    }

    private func showError(_ lead: String, _ error: Error) {
        let detail = error.mvUserMessage
        environment.toasts.show(MVToast(variant: .error, message: "\(lead): \(detail)", duration: 0))
    }
}
