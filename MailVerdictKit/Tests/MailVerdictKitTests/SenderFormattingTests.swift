import XCTest
@testable import MailVerdictKit

final class SenderFormattingTests: XCTestCase {

    func testExtractSenderNameFromNameAndAddress() {
        XCTAssertEqual(extractSenderName("\"Jane Doe\" <jane@example.com>"), "Jane Doe")
        XCTAssertEqual(extractSenderName("Jane Doe <jane@example.com>"), "Jane Doe")
    }

    func testExtractSenderNameFromBareAddressUsesTheLocalPart() {
        XCTAssertEqual(extractSenderName("jane@example.com"), "jane")
    }

    func testExtractSenderNameOfNilIsUnknown() {
        XCTAssertEqual(extractSenderName(nil), "Unknown")
    }

    func testExtractEmailFromNameAndAddress() {
        XCTAssertEqual(extractEmail("Jane Doe <jane@example.com>"), "jane@example.com")
    }

    func testExtractEmailOfABareAddressIsUnchanged() {
        XCTAssertEqual(extractEmail("jane@example.com"), "jane@example.com")
    }

    func testGetInitialsFromTwoWords() {
        XCTAssertEqual(getInitials("Jane Doe"), "JD")
    }

    func testGetInitialsFromOneWordUsesTheFirstTwoLetters() {
        XCTAssertEqual(getInitials("Jane"), "JA")
    }

    func testFormatRecipientListOfNilOrEmptyIsNil() {
        XCTAssertNil(formatRecipientList(nil))
        XCTAssertNil(formatRecipientList([]))
    }

    func testFormatRecipientListUnderTheLimitJoinsAll() {
        XCTAssertEqual(formatRecipientList(["a@example.com", "b@example.com"]), "a@example.com, b@example.com")
    }

    func testFormatRecipientListOverTheLimitTruncatesWithACount() {
        let addrs = (0..<5).map { "\($0)@example.com" }
        XCTAssertEqual(
            formatRecipientList(addrs, maxShown: 3), "0@example.com, 1@example.com, 2@example.com +2 more"
        )
    }

    func testParseAddressListSplitsOnCommaOrSemicolon() {
        XCTAssertEqual(
            parseAddressList("a@example.com, b@example.com; c@example.com"),
            [
                "a@example.com", "b@example.com", "c@example.com",
            ])
    }

    func testParseAddressListDropsEmptyEntries() {
        XCTAssertEqual(parseAddressList("a@example.com,,  ,b@example.com"), ["a@example.com", "b@example.com"])
    }

    func testIsValidEmailAcceptsAnOrdinaryAddress() {
        XCTAssertTrue(isValidEmail("a@example.com"))
    }

    func testIsValidEmailRejectsAPlainWord() {
        XCTAssertFalse(isValidEmail("nonsense"))
        XCTAssertFalse(isValidEmail("a b@example.com"))
        XCTAssertFalse(isValidEmail("a@example"))
    }

    func testAvatarColorIsStableForTheSameIdentity() {
        XCTAssertEqual(avatarColorHex(for: "jane@example.com"), avatarColorHex(for: "jane@example.com"))
    }

    func testAvatarColorIsFromThePalette() {
        XCTAssertTrue(MVAvatarPalette.colors.contains(avatarColorHex(for: "jane@example.com")))
    }
}
