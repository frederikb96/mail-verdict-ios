import Foundation
import XCTest

@testable import MailVerdictKit

final class ComposeReplyIdentityTests: XCTestCase {

    static let accountId = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!

    static func message(
        from: String = "Ann Example <ann@example.com>", to: [String] = ["me@example.com"], cc: [String] = [],
        subject: String? = "Plans", messageId: String? = "<m2@example.com>",
        references: [String]? = ["<m1@example.com>"],
        bodyText: String? = "line one\nline two", replyTo: String? = nil
    ) -> MessageDetail {
        MessageDetail(
            id: UUID(), accountId: accountId, folderId: UUID(), threadId: UUID(), subject: subject, fromAddr: from,
            toAddrs: .array(to), receivedAt: Date(timeIntervalSince1970: 0), snippet: nil, messageId: messageId,
            ccAddrs: .array(cc), bccAddrs: nil, replyTo: replyTo, inReplyTo: nil, references: references,
            bodyText: bodyText, bodyHtml: nil, sizeBytes: nil, createdAt: Date(), verdict: nil)
    }

    static func identity(_ address: String, accountId: UUID = accountId, isDefault: Bool = false) -> IdentityResponse {
        IdentityResponse(
            id: UUID(), accountId: accountId, address: address, displayName: nil, isDefault: isDefault,
            createdAt: Date())
    }

    func testReplyAllCopiesEveryoneButTheSenderAndOwnAddresses() {
        let source = Self.message(
            to: ["ME@example.com", "Bob <bob@example.com>"],
            cc: ["alias@example.com", "carol@example.com", "bob@example.com"])
        let draft = ComposeReply.reply(
            to: source, ownAddresses: ["me@example.com", "Alias <alias@example.com>"], mode: .replyAll,
            formatDate: { _ in "D" })
        XCTAssertEqual(draft.to, ["ann@example.com"])
        XCTAssertEqual(draft.cc, ["bob@example.com", "carol@example.com"])
        XCTAssertEqual(draft.references, ["<m1@example.com>", "<m2@example.com>"])
        XCTAssertEqual(draft.inReplyTo, "<m2@example.com>")
        XCTAssertEqual(draft.attribution, "On D, Ann Example wrote:")
        XCTAssertEqual(draft.quotedText, "\n\nOn D, Ann Example wrote:\n> line one\n> line two")
    }

    func testReplyGoesToEveryReplyToAddressRatherThanFrom() {
        let draft = ComposeReply.reply(
            to: Self.message(replyTo: #""List, Team" <list@example.com>, bob@example.com"#), ownAddresses: [],
            mode: .reply)
        XCTAssertEqual(draft.to, ["list@example.com", "bob@example.com"])
        XCTAssertEqual(draft.cc, [])
    }

    /// Reply-all with a Reply-To answers it plus the original To and Cc; From is not added back.
    func testReplyAllWithReplyToCopiesToAndCcButNotFrom() {
        let source = Self.message(
            to: ["me@example.com", "carol@example.com"], cc: ["List <list@example.com>", "dave@example.com"],
            replyTo: "list@example.com")
        let draft = ComposeReply.reply(to: source, ownAddresses: ["me@example.com"], mode: .replyAll)
        XCTAssertEqual(draft.to, ["list@example.com"])
        XCTAssertEqual(draft.cc, ["carol@example.com", "dave@example.com"])
    }

    func testPlainReplyCopiesNobodyAndNeverDoublesThePrefix() {
        let draft = ComposeReply.reply(
            to: Self.message(cc: ["carol@example.com"], subject: "RE: Plans"), ownAddresses: [], mode: .reply)
        XCTAssertEqual(draft.cc, [])
        XCTAssertEqual(draft.subject, "RE: Plans")
    }

    func testForwardStartsItsOwnThreadAndCarriesTheHeaderBlock() {
        let forward = ComposeReply.forward(Self.message(subject: "Fw: Plans"), formatDate: { _ in "D" })
        XCTAssertEqual(forward.subject, "Fw: Plans")
        XCTAssertEqual(
            forward.attribution,
            "---------- Forwarded message ----------\nFrom: Ann Example <ann@example.com>\nDate: D\nSubject: Fw: Plans\nTo: me@example.com"
        )
        XCTAssertEqual(ComposeReply.forward(Self.message(subject: nil)).subject, "Fwd: (no subject)")
    }

    func testMatchIdentityPrefersAddressesInTheOrderGiven() {
        let direct = Self.identity("direct@example.com")
        let copied = Self.identity("copied@example.com")
        let matched = ComposeIdentityRules.matchIdentity(
            ["Someone <COPIED@example.com>", "direct@example.com"], in: [direct, copied])
        XCTAssertEqual(matched, copied.id)
        XCTAssertNil(ComposeIdentityRules.matchIdentity(["nobody@example.com"], in: [direct]))
    }

    /// The stand-in for an account with no identity names no row, so it must never become an
    /// `identity_id` — the server would reject the send.
    func testAccountWithoutIdentitiesOffersAStandInWithNoIdentityId() {
        let bare = ComposeFixtureFactory.account(id: UUID(), imapUser: "login@bare.test")
        let withIdentities = ComposeFixtureFactory.account(id: Self.accountId, imapUser: "login@example.com")
        let starred = Self.identity("star@example.com", isDefault: true)
        let addresses = ComposeIdentityRules.pickableAddresses(
            accounts: [withIdentities, bare], identities: [Self.identity("plain@example.com"), starred])
        XCTAssertEqual(addresses.map(\.address), ["plain@example.com", "star@example.com", "login@bare.test"])
        XCTAssertNil(addresses[2].identityId)
        XCTAssertEqual(
            ComposeIdentityRules.defaultAddress(in: addresses, accountId: Self.accountId)?.address, "star@example.com")
        XCTAssertEqual(
            ComposeIdentityRules.resolve(in: addresses, preferring: [nil, bare.id])?.address, "login@bare.test")
    }

    func testRecipientCommitKeepsInvalidEntriesAndSkipsDuplicates() {
        let result = ComposeRecipients.commit(
            "Bob <bob@example.com>; not-an-address, ANN@example.com,", into: ["ann@example.com"])
        XCTAssertEqual(result.recipients, ["ann@example.com", "bob@example.com"])
        XCTAssertEqual(result.invalid, ["not-an-address"])
        XCTAssertEqual(ComposeRecipients.invalidNote(result.invalid), "Not a valid email address: not-an-address")
    }
}

enum ComposeFixtureFactory {
    static func account(id: UUID, imapUser: String, name: String = "Account") -> AccountResponse {
        AccountResponse(
            id: id, name: name, imapHost: "imap.test", imapPort: 993, imapUser: imapUser, smtpHost: nil, smtpPort: nil,
            smtpUser: nil, stateError: nil, capabilities: nil, createdAt: Date(), updatedAt: Date(), emoji: nil,
            folderOrder: nil, trashRetentionDays: nil, junkRetentionDays: nil)
    }
}
