import XCTest
@testable import MailVerdictKit

final class MVAccountFormModelTests: XCTestCase {

    // MARK: - Create validation

    func testCreateRejectsAMissingName() async throws {
        var input = MVAccountFormInput()
        input.imapHost = "imap.example.com"
        input.imapUser = "user@example.com"
        XCTAssertThrowsError(try MVAccountFormModel.buildCreateRequest(input)) { error in
            XCTAssertEqual(error as? MVAccountFormError, .missingName)
        }
    }

    func testCreateRejectsAnInvalidImapPort() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.imapHost = "imap.example.com"
        input.imapUser = "user@example.com"
        input.imapPort = "not-a-number"
        XCTAssertThrowsError(try MVAccountFormModel.buildCreateRequest(input)) { error in
            XCTAssertEqual(error as? MVAccountFormError, .invalidImapPort)
        }
    }

    func testCreateBuildsARequestWithOptionalFieldsOmittedWhenBlank() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.imapHost = "imap.example.com"
        input.imapUser = "user@example.com"
        input.imapPort = "993"
        let request = try MVAccountFormModel.buildCreateRequest(input)
        XCTAssertEqual(request.imapPort, 993)
        XCTAssertNil(request.smtpHost)
        XCTAssertNil(request.trashRetentionDays)
    }

    /// Zero and negative values clear the entire retention-tracked folder on the very next sweep
    /// rather than meaning "off" — the same floor the backend's own `ge=1` constraint enforces.
    func testCreateRejectsARetentionOfZero() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.imapHost = "imap.example.com"
        input.imapUser = "user@example.com"
        input.trashRetentionDays = "0"
        XCTAssertThrowsError(try MVAccountFormModel.buildCreateRequest(input)) { error in
            XCTAssertEqual(error as? MVAccountFormError, .invalidTrashRetention)
        }
    }

    // MARK: - Update body: the null-vs-omitted distinction

    /// The field the account edit form can actually clear back to "Off" — omitting the key
    /// (what a typed `Encodable` would do for a `nil` property) leaves the old value in place on
    /// a route read with `exclude_unset`; only an explicit JSON `null` clears it.
    func testUpdateBodySendsExplicitNullWhenRetentionIsCleared() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.trashRetentionDays = ""
        input.junkRetentionDays = ""
        let body = try MVAccountFormModel.buildUpdateBody(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertTrue(object.keys.contains("trash_retention_days"))
        XCTAssertTrue(object["trash_retention_days"] is NSNull)
        XCTAssertTrue(object.keys.contains("junk_retention_days"))
        XCTAssertTrue(object["junk_retention_days"] is NSNull)
    }

    func testUpdateBodyCarriesARetentionValueWhenSet() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.trashRetentionDays = "30"
        let body = try MVAccountFormModel.buildUpdateBody(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["trash_retention_days"] as? Int, 30)
    }

    /// Unlike retention, a blank SMTP field means "leave it alone" — the edit form has no way to
    /// clear a configured SMTP host, matching the web form it ports.
    func testUpdateBodyOmitsSmtpFieldsWhenBlankRatherThanNullingThem() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.smtpHost = ""
        input.smtpUser = ""
        input.imapPassword = ""
        let body = try MVAccountFormModel.buildUpdateBody(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertFalse(object.keys.contains("smtp_host"))
        XCTAssertFalse(object.keys.contains("smtp_user"))
        XCTAssertFalse(object.keys.contains("imap_password"))
    }

    func testUpdateBodyNeverIncludesTheLockedImapFields() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.imapHost = "imap.example.com"
        input.imapPort = "993"
        input.imapUser = "user@example.com"
        let body = try MVAccountFormModel.buildUpdateBody(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertFalse(object.keys.contains("imap_host"))
        XCTAssertFalse(object.keys.contains("imap_port"))
        XCTAssertFalse(object.keys.contains("imap_user"))
    }

    func testUpdateBodyRejectsAMissingName() async throws {
        let input = MVAccountFormInput()
        XCTAssertThrowsError(try MVAccountFormModel.buildUpdateBody(input)) { error in
            XCTAssertEqual(error as? MVAccountFormError, .missingName)
        }
    }
}
