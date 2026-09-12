import Foundation
import XCTest

@testable import MailVerdictKit

final class ComposeSubmissionTests: XCTestCase {

    private func input(
        document: ComposeDocument, attachments: [ComposeAttachment] = [], images: [ComposeInlineImage] = [],
        quote: ComposeQuote? = nil, quotedText: String = ""
    ) -> ComposeSubmissionInput {
        ComposeSubmissionInput(
            accountId: UUID(), kind: .send, to: ["a@b.test"], cc: [], bcc: [], subject: "S", document: document,
            quote: quote, quotedText: quotedText, inReplyTo: nil, references: nil, identityId: nil,
            replacesMessageId: nil, attachments: attachments,
            inlineImages: Dictionary(uniqueKeysWithValues: images.map { ($0.contentId, $0) }), idempotencyKey: UUID())
    }

    private func image(_ id: String) -> ComposeInlineImage {
        ComposeInlineImage(contentId: id, filename: "\(id).png", contentType: "image/png", data: Data(id.utf8))
    }

    /// The server pairs `inline_attachment_content_ids` with the uploaded files by position, so a
    /// misalignment attaches a picked file as an inline image or the other way round.
    func testUploadsAndContentIdsLineUpPositionForPosition() {
        let file = ComposeAttachment(filename: "report.pdf", contentType: "application/pdf", data: Data("pdf".utf8))
        let document = ComposeDocument(blocks: [
            ComposeBlock(.paragraph, [ComposeRun(.image(ComposeImageRef(contentId: "second")))]),
            ComposeBlock(.paragraph, [.text("x"), ComposeRun(.image(ComposeImageRef(contentId: "first")))]),
        ])
        let built = ComposeSubmission.build(
            input(document: document, attachments: [file], images: [image("first"), image("second"), image("deleted")]))

        XCTAssertEqual(built.uploads.map(\.filename), ["report.pdf", "second.png", "first.png"])
        XCTAssertEqual(built.request.inlineAttachmentContentIds, [nil, "second", "first"])
        XCTAssertEqual(built.request.bodyHtml?.contains("src=\"cid:second\""), true)
    }

    /// A body referencing an image whose bytes are gone (a reopened draft's own inline image)
    /// must not send a `cid:` nothing resolves.
    func testImageWithoutBytesIsNeitherReferencedNorUploaded() {
        let document = ComposeDocument(blocks: [
            ComposeBlock(.paragraph, [.text("hi"), ComposeRun(.image(ComposeImageRef(contentId: "gone")))])
        ])
        let built = ComposeSubmission.build(input(document: document))
        XCTAssertTrue(built.uploads.isEmpty)
        XCTAssertNil(built.request.inlineAttachmentContentIds)
        XCTAssertEqual(built.request.bodyHtml, "<p>hi</p>")
    }

    func testTextBodyAppendsTheQuotedPlainText() {
        let built = ComposeSubmission.build(
            input(
                document: ComposeDocument(blocks: [ComposeBlock(.paragraph, [.text("Thanks", [.bold])])]),
                quote: ComposeQuote(html: "<p>old</p>", attribution: "On D, A wrote:"),
                quotedText: "\n\nOn D, A wrote:\n> old"))
        XCTAssertEqual(built.request.bodyText, "**Thanks**\n\nOn D, A wrote:\n> old")
        XCTAssertEqual(
            built.request.bodyHtml?.hasPrefix("<p><strong>Thanks</strong></p><div data-quoted-message"), true)
    }
}
