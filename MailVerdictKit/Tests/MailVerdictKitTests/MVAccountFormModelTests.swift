import Foundation
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

    // MARK: - Update request: the null-vs-omitted distinction

    private func encoded(_ request: AccountUpdateRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The field the account edit form can actually clear back to "Off" — omitting the key
    /// (what a typed `Encodable` would do for a plain `nil` property) leaves the old value in
    /// place on a route read with `exclude_unset`; only an explicit JSON `null` clears it.
    func testUpdateRequestSendsExplicitNullWhenRetentionIsCleared() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.trashRetentionDays = ""
        input.junkRetentionDays = ""
        let object = try encoded(MVAccountFormModel.buildUpdateRequest(input))
        XCTAssertTrue(object.keys.contains("trash_retention_days"))
        XCTAssertTrue(object["trash_retention_days"] is NSNull)
        XCTAssertTrue(object.keys.contains("junk_retention_days"))
        XCTAssertTrue(object["junk_retention_days"] is NSNull)
    }

    func testUpdateRequestCarriesARetentionValueWhenSet() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.trashRetentionDays = "30"
        let object = try encoded(MVAccountFormModel.buildUpdateRequest(input))
        XCTAssertEqual(object["trash_retention_days"] as? Int, 30)
    }

    /// Unlike retention, a blank SMTP field means "leave it alone" — the edit form has no way to
    /// clear a configured SMTP host, matching the web form it ports.
    func testUpdateRequestOmitsSmtpFieldsWhenBlankRatherThanNullingThem() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.smtpHost = ""
        input.smtpUser = ""
        input.imapPassword = ""
        let object = try encoded(MVAccountFormModel.buildUpdateRequest(input))
        XCTAssertFalse(object.keys.contains("smtp_host"))
        XCTAssertFalse(object.keys.contains("smtp_user"))
        XCTAssertFalse(object.keys.contains("imap_password"))
    }

    func testUpdateRequestNeverIncludesTheLockedImapFields() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.imapHost = "imap.example.com"
        input.imapPort = "993"
        input.imapUser = "user@example.com"
        let object = try encoded(MVAccountFormModel.buildUpdateRequest(input))
        XCTAssertFalse(object.keys.contains("imap_host"))
        XCTAssertFalse(object.keys.contains("imap_port"))
        XCTAssertFalse(object.keys.contains("imap_user"))
    }

    func testUpdateRequestRejectsAMissingName() async throws {
        let input = MVAccountFormInput()
        XCTAssertThrowsError(try MVAccountFormModel.buildUpdateRequest(input)) { error in
            XCTAssertEqual(error as? MVAccountFormError, .missingName)
        }
    }

    // MARK: - Glacier: the same leave/clear/set shape as retention

    func testCreateRequestNeverCarriesGlacierFields() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.imapHost = "imap.example.com"
        input.imapUser = "user@example.com"
        input.glacierEnabled = true
        input.glacierAutoDays = "90"
        // AccountCreateRequest has no glacier fields at all -- a glacier can only be configured
        // once the account exists, the same gate the web form uses.
        _ = try MVAccountFormModel.buildCreateRequest(input)
    }

    func testUpdateRequestSendsExplicitNullWhenTheAutomaticSweepIsCleared() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.glacierAutoDays = ""
        let object = try encoded(MVAccountFormModel.buildUpdateRequest(input))
        XCTAssertTrue(object.keys.contains("glacier_auto_days"))
        XCTAssertTrue(object["glacier_auto_days"] is NSNull)
    }

    func testUpdateRequestCarriesTheGlacierSwitchAndDaysWhenSet() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.glacierEnabled = true
        input.glacierAutoDays = "90"
        let object = try encoded(MVAccountFormModel.buildUpdateRequest(input))
        XCTAssertEqual(object["glacier_enabled"] as? Bool, true)
        XCTAssertEqual(object["glacier_auto_days"] as? Int, 90)
    }

    /// Same floor as trash/junk retention: a value below 1 would sweep the account's whole
    /// archive on the very next tick rather than meaning "off".
    func testUpdateRequestRejectsAnAutomaticSweepOfZero() async throws {
        var input = MVAccountFormInput()
        input.name = "Work"
        input.glacierAutoDays = "0"
        XCTAssertThrowsError(try MVAccountFormModel.buildUpdateRequest(input)) { error in
            XCTAssertEqual(error as? MVAccountFormError, .invalidGlacierAutoDays)
        }
    }

    func testFormInputPrefillsFromAnAccountsGlacierFields() {
        let account = AccountResponse(
            id: UUID(), name: "Work", imapHost: "imap.example.com", imapPort: 993,
            imapUser: "user@example.com", smtpHost: nil, smtpPort: nil, smtpUser: nil, stateError: nil,
            capabilities: nil, createdAt: Date(), updatedAt: Date(), emoji: nil, folderOrder: nil,
            trashRetentionDays: nil, junkRetentionDays: nil, glacierEnabled: true, glacierAutoDays: 30
        )
        let input = MVAccountFormInput(account: account)
        XCTAssertTrue(input.glacierEnabled)
        XCTAssertEqual(input.glacierAutoDays, "30")
    }

    func testFormInputPrefillsManualOnlyAsAnEmptyField() {
        let account = AccountResponse(
            id: UUID(), name: "Work", imapHost: "imap.example.com", imapPort: 993,
            imapUser: "user@example.com", smtpHost: nil, smtpPort: nil, smtpUser: nil, stateError: nil,
            capabilities: nil, createdAt: Date(), updatedAt: Date(), emoji: nil, folderOrder: nil,
            trashRetentionDays: nil, junkRetentionDays: nil, glacierEnabled: true, glacierAutoDays: nil
        )
        let input = MVAccountFormInput(account: account)
        XCTAssertTrue(input.glacierEnabled)
        XCTAssertEqual(input.glacierAutoDays, "")
    }
}

/// `UnifiedViewUpdate.emoji`'s own `??` is the same "leave it / clear it / set it" encoding the
/// account update request uses — the shared mechanism's second call site.
final class UnifiedViewUpdateTests: XCTestCase {

    private func encoded(_ update: UnifiedViewUpdate) throws -> [String: Any] {
        let data = try JSONEncoder().encode(update)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testClearingTheEmojiSendsAnExplicitNull() throws {
        let object = try encoded(UnifiedViewUpdate(emoji: .some(nil)))
        XCTAssertEqual(Array(object.keys), ["emoji"])
        XCTAssertTrue(object["emoji"] is NSNull)
    }

    func testSettingTheEmojiSendsItsValue() throws {
        let object = try encoded(UnifiedViewUpdate(emoji: .some("📥")))
        XCTAssertEqual(object["emoji"] as? String, "📥")
    }

    func testLeavingTheEmojiUntouchedOmitsItEntirely() throws {
        let object = try encoded(UnifiedViewUpdate(name: "Work"))
        XCTAssertEqual(Array(object.keys), ["name"])
    }
}
