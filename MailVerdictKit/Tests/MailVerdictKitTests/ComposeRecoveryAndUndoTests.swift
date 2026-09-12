import Foundation
import XCTest

@testable import MailVerdictKit

final class ComposeRecoveryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("compose-recovery-\(UUID())")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func content(attachments: [ComposeAttachment]) -> ComposeRecoveryContent {
        ComposeRecoveryContent(
            to: ["a@b.test"], cc: [], bcc: ["c@d.test"], subject: "S",
            document: ComposeDocument(blocks: [ComposeBlock(.quote, [.text("q")])]),
            quote: ComposeQuote(html: "<p>o</p>", attribution: "On D"), attachments: attachments,
            inlineImages: [
                ComposeInlineImage(contentId: "c<1>", filename: "i.png", contentType: "image/png", data: Data([1]))
            ])
    }

    func testSnapshotRoundTripsFilesAndDropsOnesNoLongerAttached() throws {
        let store = ComposeRecoveryStore(directory: directory)
        let key = ComposeRecoveryStore.key(replacesMessageId: nil, inReplyTo: "<m1@example.com>")
        let kept = ComposeAttachment(filename: "kept.pdf", contentType: nil, data: Data("k".utf8))
        let dropped = ComposeAttachment(filename: "gone.pdf", contentType: nil, data: Data("g".utf8))

        try store.write(content(attachments: [kept, dropped]), key: key)
        try store.write(content(attachments: [kept]), key: key)

        XCTAssertEqual(store.read(key: key), content(attachments: [kept]))
        let folder = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent(folder[0]).path)
        XCTAssertFalse(files.contains("attachment-\(dropped.id.uuidString)"))

        store.clear(key: key)
        XCTAssertNil(store.read(key: key))
    }

    func testKeysSeparateDraftsRepliesAndNewMessages() {
        let draft = UUID()
        XCTAssertEqual(
            ComposeRecoveryStore.key(replacesMessageId: draft, inReplyTo: "<x>"),
            "draft:\(draft.uuidString.lowercased())")
        XCTAssertEqual(ComposeRecoveryStore.key(replacesMessageId: nil, inReplyTo: "<x>"), "reply:<x>")
        XCTAssertEqual(ComposeRecoveryStore.key(replacesMessageId: nil, inReplyTo: nil), "new")
    }
}

@MainActor
final class UndoSendStoreTests: XCTestCase {

    private func row(attachments: [PendingSendAttachmentSummary] = []) -> PendingSendResponse {
        PendingSendResponse(
            id: UUID(), accountId: UUID(), sendAfter: Date().addingTimeInterval(10), createdAt: Date(),
            fromAddr: "me@x.test",
            to: ["a@b.test"], cc: nil, bcc: nil, subject: "S", bodyHtml: "<p>x</p>", inReplyTo: nil, references: nil,
            replacesMessageId: nil, attachments: attachments)
    }

    func testRestorationPutsPastedImagesBackInTheBodyAndNamesWhatFailed() async {
        let inline = PendingSendAttachmentSummary(
            id: UUID(), filename: "p.png", contentType: "image/png", sizeBytes: 1, contentId: "img1")
        let file = PendingSendAttachmentSummary(
            id: UUID(), filename: "doc.pdf", contentType: nil, sizeBytes: 1, contentId: nil)
        let lost = PendingSendAttachmentSummary(
            id: UUID(), filename: "lost.zip", contentType: nil, sizeBytes: 1, contentId: nil)
        let restoration = UndoSendRestoration.build(
            row: row(attachments: [inline, file, lost]),
            fetched: [
                .success((Data([1]), nil)), .success((Data([2]), "application/pdf")), .failure(MVError.transport("x")),
            ])
        XCTAssertEqual(restoration.inlineImages.map(\.contentId), ["img1"])
        XCTAssertEqual(restoration.attachments.map(\.filename), ["doc.pdf"])
        XCTAssertEqual(restoration.attachments.first?.contentType, "application/pdf")
        XCTAssertEqual(restoration.missing, ["lost.zip"])
    }

    func testUndoKeepsTheRestorationUntilForgottenAndATooLateCancelDropsTheRow() async {
        let pending = row()
        let refused = row()
        let refusedId = refused.id
        let store = UndoSendStore(
            dependencies: UndoSendDependencies(
                listPending: { [] },
                cancel: { id in if id == refusedId { throw MVError.transport("already sent") } },
                getAttachment: { _, _ in (Data(), nil, nil) }))
        store.add(pending)
        store.add(refused)

        guard case .restored(let intent) = await store.undo(pending.id), case .undoRestore(let restoredId) = intent.kind
        else { return XCTFail("expected the composer to reopen on the cancelled send") }
        XCTAssertEqual(restoredId, pending.id)
        XCTAssertNotNil(store.restoration(for: pending.id))
        XCTAssertNotNil(store.restoration(for: pending.id), "a second read finds the same restoration")
        store.forgetRestoration(for: pending.id)
        XCTAssertNil(store.restoration(for: pending.id))

        let refusedOutcome = await store.undo(refusedId)
        XCTAssertEqual(refusedOutcome, .tooLate)
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testCountdownRoundsUpAndNeverGoesNegative() {
        let now = Date()
        XCTAssertEqual(UndoSendStore.secondsRemaining(until: now.addingTimeInterval(4.1), now: now), 5)
        XCTAssertEqual(UndoSendStore.secondsRemaining(until: now.addingTimeInterval(-3), now: now), 0)
    }
}
