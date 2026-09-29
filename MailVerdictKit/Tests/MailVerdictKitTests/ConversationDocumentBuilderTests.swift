import XCTest

@testable import MailVerdictKit

final class ConversationDocumentBuilderTests: XCTestCase {

    private func message(
        _ id: UUID = UUID(), subject: String = "Hello", html: String? = "<p>body</p>", minutesAgo: Double = 5,
        isGlacier: Bool = false, originFolderName: String? = nil
    ) -> MessageDetail {
        ReaderFixtures.message(
            id: id, from: "Alice <alice@example.org>", to: ["me@example.org"], subject: subject, html: html, text: nil,
            minutesAgo: minutesAgo, isGlacier: isGlacier, originFolderName: originFolderName)
    }

    private func document(_ messages: [MessageDetail], opened: UUID) -> String {
        ConversationDocumentBuilder.document(
            for: ReaderConversation(messages: messages, openedId: opened), options: ReaderDocumentOptions(theme: .light)
        )
    }

    private func elementId(_ id: UUID) -> String {
        ConversationDocumentBuilder.messageElementId(id)
    }

    func testSubjectIsEscaped() {
        let m = message(subject: "<img src=x onerror=alert(1)>")
        let doc = document([m], opened: m.id)
        XCTAssertFalse(doc.contains("<img src=x"))
        XCTAssertTrue(doc.contains("&lt;img src=x onerror=alert(1)&gt;"))
    }

    func testOnlyTheOpenedMessageStartsExpanded() {
        let older = message(minutesAgo: 60)
        let newer = message(minutesAgo: 5)
        let doc = document([older, newer], opened: older.id)
        XCTAssertTrue(doc.contains(#"id="\#(elementId(older.id))" open>"#))
        XCTAssertTrue(doc.contains(#"id="\#(elementId(newer.id))">"#))
    }

    func testNewestMessageComesFirst() throws {
        let older = message(minutesAgo: 60)
        let newer = message(minutesAgo: 5)
        let doc = document([older, newer], opened: older.id)
        let newerAt = try XCTUnwrap(doc.range(of: elementId(newer.id))).lowerBound
        let olderAt = try XCTUnwrap(doc.range(of: elementId(older.id))).lowerBound
        XCTAssertLessThan(newerAt, olderAt)
    }

    func testTruncatedMessageShowsTheBannerInsteadOfABody() {
        var m = message()
        m.isTruncated = true
        let doc = document([m], opened: m.id)
        XCTAssertTrue(doc.contains("too large to display"))
        XCTAssertFalse(doc.contains(ConversationDocumentBuilder.bodyElementId(m.id)))
    }

    /// A glaciered message names where it used to live, alongside its body -- unlike a truncated
    /// message, the glacier banner never replaces the content, since the body is still there.
    func testGlacieredMessageShowsProvenanceAlongsideItsBody() {
        let m = message(isGlacier: true, originFolderName: "Archive")
        let doc = document([m], opened: m.id)
        XCTAssertTrue(doc.contains("in the glacier"))
        XCTAssertTrue(doc.contains("was in Archive"))
        XCTAssertTrue(doc.contains(ConversationDocumentBuilder.bodyElementId(m.id)), "the body must still render")
    }

    /// Merging lucide's twelve subpaths into one `d` string breaks it -- every `m` after the first
    /// is relative to the previous subpath's own end point rather than to the canvas origin, which
    /// scrambles the icon into disconnected fragments (confirmed by rendering both forms outside
    /// this test). Twelve separate `<path>` elements is what actually stays correct.
    func testSnowflakeGlyphIsTwelveSeparatePathElementsNotOneMergedPath() {
        let glyph = ConversationDocumentBuilder.snowflakeGlyph
        XCTAssertEqual(glyph.components(separatedBy: "<path").count - 1, 12)
        XCTAssertEqual(glyph.components(separatedBy: "</path>").count - 1, 0, "self-closing, not paired")
        XCTAssertTrue(glyph.contains(#"<svg class="mv-glyph" viewBox="0 0 24 24""#))
    }

    /// No origin folder name (a copy made before that column existed, say) drops the parenthetical
    /// rather than rendering an empty one.
    func testGlacieredMessageWithNoOriginFolderOmitsTheParenthetical() {
        let m = message(isGlacier: true, originFolderName: nil)
        let doc = document([m], opened: m.id)
        XCTAssertTrue(doc.contains("in the glacier"))
        XCTAssertFalse(doc.contains("(was in"))
    }

    func testAnOrdinaryMessageShowsNoGlacierBanner() {
        let m = message()
        XCTAssertFalse(document([m], opened: m.id).contains("in the glacier"))
    }

    func testImageBannerOnlyWhenImagesAreBlockedAndNotAllowed() {
        var blocked = message()
        blocked.hasBlockedImages = true
        XCTAssertTrue(document([blocked], opened: blocked.id).contains("Remote images blocked"))

        var allowed = blocked
        allowed.imagesAllowed = true
        XCTAssertFalse(document([allowed], opened: allowed.id).contains("Remote images blocked"))
    }

    func testCalendarAttachmentGetsAnInvitationSlot() {
        var m = message()
        m.attachments = [AttachmentSummary(id: UUID(), filename: "a.ics", contentType: "text/calendar", sizeBytes: 10)]
        XCTAssertTrue(document([m], opened: m.id).contains(InvitationCardBuilder.slotId(messageId: m.id)))
    }

    func testAnUnopenedDraftOpensTheComposer() {
        var draft = message(minutesAgo: 1)
        draft.isDraft = true
        let opened = message(minutesAgo: 30)
        let doc = document([opened, draft], opened: opened.id)
        XCTAssertTrue(doc.contains(MVReaderLink.draft(messageId: draft.id).url))
        XCTAssertFalse(doc.contains(ConversationDocumentBuilder.bodyElementId(draft.id)))
    }

    func testEveryShownBodySitsInItsOwnShadowRoot() {
        let a = message(minutesAgo: 60)
        let b = message(minutesAgo: 30, )
        var truncated = message(minutesAgo: 10)
        truncated.isTruncated = true
        let doc = document([a, b, truncated], opened: b.id)
        XCTAssertEqual(doc.components(separatedBy: #"shadowrootmode="open""#).count - 1, 2)
    }

    func testOnlyANonPrimaryMessageGetsTheOpenControl() {
        let older = message(minutesAgo: 60)
        let newer = message(minutesAgo: 5)
        let doc = document([older, newer], opened: newer.id)
        XCTAssertTrue(doc.contains(MVReaderLink.openMessage(messageId: older.id).url))
        XCTAssertFalse(doc.contains(MVReaderLink.openMessage(messageId: newer.id).url))
    }

    func testEveryFixturePageBuilds() {
        for (rowId, thread) in ReaderFixtures.threads() {
            let doc = document(thread.messages, opened: rowId)
            XCTAssertTrue(doc.contains(#"data-primary="\#(rowId.uuidString.lowercased())""#), "\(rowId)")
        }
    }
}
