import Foundation
import XCTest

@testable import MailVerdictKit

private actor Recorder {
    private(set) var requests: [OutboxCreateRequest] = []
    func record(_ request: OutboxCreateRequest) { requests.append(request) }
}

@MainActor
final class ComposerStoreTests: XCTestCase {

    private let accountId = ComposeReplyIdentityTests.accountId

    private func outboxResponse() -> OutboxResponse {
        OutboxResponse(
            id: UUID(), accountId: accountId, kind: "send", status: "queued", fromAddr: nil, cc: nil, bcc: nil,
            subject: nil, error: nil, createdAt: Date(), updatedAt: Date())
    }

    private func dependencies(
        recorder: Recorder, message: MessageDetail? = nil, identities: [IdentityResponse] = [],
        failSubmit: Bool = false, recovery: ComposeRecoveryStore? = nil
    ) -> ComposerDependencies {
        let accountId = accountId
        let response = outboxResponse()
        return ComposerDependencies(
            listAccounts: { [ComposeFixtureFactory.account(id: accountId, imapUser: "me@example.com")] },
            listIdentities: { identities },
            getMessage: { _ in
                guard let message else { throw MVError.transport("no message") }
                return message
            },
            getQuote: { _ in MessageQuoteResponse(html: "<p>quoted</p>") },
            getAttachment: { _, _ in (Data(), nil, nil) },
            createOutbox: { request, _ in
                await recorder.record(request)
                try await Task.sleep(for: .milliseconds(20))
                if failSubmit { throw MVError.transport("offline") }
                return .sent(response)
            },
            recovery: recovery)
    }

    /// Two taps landing before the first request returns must send one message, not two.
    func testSecondSubmitWhileFirstIsInFlightIsIgnored() async {
        let recorder = Recorder()
        let store = ComposerStore(
            intent: ComposeIntent(kind: .new(accountId: nil)), dependencies: dependencies(recorder: recorder))
        await store.load()
        store.addRecipient("bob@example.com", to: .to)

        async let first = store.submit(.send)
        async let second = store.submit(.send)
        let outcomes = await [first, second]

        let requestCount = await recorder.requests.count
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(outcomes.contains(.sent))
        XCTAssertTrue(outcomes.contains(.ignored))
        let afterCompletion = await store.submit(.send)
        XCTAssertEqual(afterCompletion, .ignored, "a completed composer has nothing left to send")
    }

    func testSendWithoutRecipientIsRefusedWithAHint() async {
        let recorder = Recorder()
        let store = ComposerStore(
            intent: ComposeIntent(kind: .new(accountId: nil)), dependencies: dependencies(recorder: recorder))
        await store.load()
        store.updateRecipientText("not an address", for: .to)

        let withInvalidText = await store.submit(.send)
        XCTAssertEqual(withInvalidText, .blocked)
        XCTAssertEqual(store.recipientNotes[.to], "Not a valid email address: not an address")
        let requestCount = await recorder.requests.count
        XCTAssertEqual(requestCount, 0)

        store.updateRecipientText("", for: .to)
        let withNoRecipient = await store.submit(.send)
        XCTAssertEqual(withNoRecipient, .blocked)
        XCTAssertEqual(store.sendHint, "Add at least one recipient")
    }

    /// A failed send leaves the composer open and sendable again, with the same idempotency key —
    /// a retry the server already received must not become a second message.
    func testFailedSendCanBeRetriedWithTheSameIdempotencyKey() async {
        let recorder = Recorder()
        let store = ComposerStore(
            intent: ComposeIntent(kind: .new(accountId: nil)),
            dependencies: dependencies(recorder: recorder, failSubmit: true))
        await store.load()
        store.addRecipient("bob@example.com", to: .to)

        let failed = await store.submit(.send)
        XCTAssertEqual(failed, .failed("Not sent: \(MVError.transport("offline").userMessage)"))
        XCTAssertEqual(store.phase, .editing)
        _ = await store.submit(.send)
        let keys = await recorder.requests.map(\.idempotencyKey)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1])
    }

    /// A reply sends as the identity the original reached, from that account only, and counts as
    /// clean until someone edits it.
    func testReplyLoadsQuoteRecipientsAndMatchingIdentity() async {
        let alias = ComposeReplyIdentityTests.identity("alias@example.com")
        let other = ComposeReplyIdentityTests.identity("main@example.com", isDefault: true)
        let message = ComposeReplyIdentityTests.message(to: ["alias@example.com"])
        let store = ComposerStore(
            intent: ComposeIntent(kind: .reply(messageId: message.id)),
            dependencies: dependencies(recorder: Recorder(), message: message, identities: [other, alias]))
        await store.load()

        XCTAssertEqual(store.phase, .editing)
        XCTAssertEqual(store.recipients(.to), ["ann@example.com"])
        XCTAssertEqual(store.subject, "Re: Plans")
        XCTAssertEqual(store.quote?.html, "<p>quoted</p>")
        XCTAssertEqual(store.selectedFrom?.identityId, alias.id)
        XCTAssertEqual(store.inReplyTo, "<m2@example.com>")
        XCTAssertFalse(store.isDirty)
        store.editorDidChange(ComposeDocument(blocks: [ComposeBlock(.paragraph, [.text("Sure")])]))
        XCTAssertTrue(store.isDirty)
    }

    func testRecoverySnapshotIsOfferedToTheSameComposerAndClearedOnDiscard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compose-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = ComposeRecoveryStore(directory: directory)
        let deps = dependencies(recorder: Recorder(), recovery: recovery)

        let first = ComposerStore(intent: ComposeIntent(kind: .new(accountId: nil)), dependencies: deps)
        await first.load()
        first.addRecipient("bob@example.com", to: .to)
        first.addAttachments([ComposeAttachment(filename: "a.txt", contentType: "text/plain", data: Data("hi".utf8))])
        first.saveRecoverySnapshot()

        let second = ComposerStore(intent: ComposeIntent(kind: .new(accountId: nil)), dependencies: deps)
        await second.load()
        XCTAssertEqual(second.recoverable?.to, ["bob@example.com"])
        second.restoreRecovered()
        XCTAssertEqual(second.attachments.map(\.data), [Data("hi".utf8)])
        XCTAssertTrue(second.isDirty, "restored content exists nowhere else yet")
        second.discard()
        XCTAssertFalse(recovery.hasSnapshot(key: "new"))
    }
}
