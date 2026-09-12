import Foundation

/// Everything the add/edit account sheet needs from its text fields before a request can be
/// built — plain strings, because that is what a `TextField` binds to; parsing and validation
/// happen once, in `buildCreateBody`/`buildUpdateBody`, not per keystroke.
public struct MVAccountFormInput: Equatable, Sendable {
    public var name: String = ""
    public var imapHost: String = ""
    public var imapPort: String = "993"
    public var imapUser: String = ""
    public var imapPassword: String = ""
    public var smtpHost: String = ""
    public var smtpPort: String = ""
    public var smtpUser: String = ""
    public var smtpPassword: String = ""
    public var spamEnabled: Bool = false
    /// Empty means "Off" (no retention sweep) — the placeholder text both the web form and this
    /// one use for that state.
    public var trashRetentionDays: String = ""
    public var junkRetentionDays: String = ""

    public init() {}

    /// Pre-fills an edit — `imapHost`/`imapPort`/`imapUser` are shown but never sent back, since
    /// PostIMAP's own contract makes them insert-only on an existing account.
    public init(account: AccountResponse) {
        name = account.name
        imapHost = account.imapHost
        imapPort = String(account.imapPort)
        imapUser = account.imapUser
        smtpHost = account.smtpHost ?? ""
        smtpPort = account.smtpPort.map(String.init) ?? ""
        smtpUser = account.smtpUser ?? ""
        spamEnabled = account.spamEnabled
        trashRetentionDays = account.trashRetentionDays.map(String.init) ?? ""
        junkRetentionDays = account.junkRetentionDays.map(String.init) ?? ""
    }
}

public enum MVAccountFormError: Error, Equatable {
    case missingName
    case missingImapHost
    case missingImapUser
    case invalidImapPort
    case invalidSmtpPort
    case invalidTrashRetention
    case invalidJunkRetention
}

public enum MVAccountFormModel {

    public static func buildCreateRequest(_ input: MVAccountFormInput) throws -> AccountCreateRequest {
        let name = try trimmedOrThrow(input.name, .missingName)
        let imapHost = try trimmedOrThrow(input.imapHost, .missingImapHost)
        let imapUser = try trimmedOrThrow(input.imapUser, .missingImapUser)
        guard let imapPort = Int(input.imapPort.trimmingCharacters(in: .whitespaces)), imapPort > 0 else {
            throw MVAccountFormError.invalidImapPort
        }
        let smtpPort = try optionalPort(input.smtpPort)
        let trashRetentionDays = try optionalRetention(input.trashRetentionDays, error: .invalidTrashRetention)
        let junkRetentionDays = try optionalRetention(input.junkRetentionDays, error: .invalidJunkRetention)
        return AccountCreateRequest(
            name: name, imapHost: imapHost, imapPort: imapPort, imapUser: imapUser,
            imapPassword: emptyToNil(input.imapPassword), smtpHost: emptyToNil(input.smtpHost),
            smtpPort: smtpPort, smtpUser: emptyToNil(input.smtpUser),
            smtpPassword: emptyToNil(input.smtpPassword), spamEnabled: input.spamEnabled,
            trashRetentionDays: trashRetentionDays, junkRetentionDays: junkRetentionDays
        )
    }

    /// `PATCH /accounts/{id}` reads its body with Pydantic's `exclude_unset`, so a field absent
    /// from the JSON means "leave it", while an explicit `null` clears it — a distinction Swift's
    /// synthesized `Encodable` cannot express (see `MVJSONLiteral`'s own doc comment). This builds
    /// the body by hand so retention can be cleared back to "Off", which a typed
    /// `AccountUpdateRequest` with a `nil` property could never do: that field would simply be
    /// missing from the request, leaving the old value in place. `imapHost`/`imapPort`/`imapUser`
    /// are never part of this body at all — they are insert-only regardless of what the disabled
    /// fields show.
    public static func buildUpdateBody(_ input: MVAccountFormInput) throws -> Data {
        let name = try trimmedOrThrow(input.name, .missingName)
        let smtpPort = try optionalPort(input.smtpPort)
        let trashRetentionDays = try optionalRetention(input.trashRetentionDays, error: .invalidTrashRetention)
        let junkRetentionDays = try optionalRetention(input.junkRetentionDays, error: .invalidJunkRetention)

        var fields = ["\"name\":\(MVJSONLiteral.string(name))"]
        if let password = emptyToNil(input.imapPassword) {
            fields.append("\"imap_password\":\(MVJSONLiteral.string(password))")
        }
        if let host = emptyToNil(input.smtpHost) {
            fields.append("\"smtp_host\":\(MVJSONLiteral.string(host))")
        }
        if let smtpPort {
            fields.append("\"smtp_port\":\(MVJSONLiteral.int(smtpPort))")
        }
        if let user = emptyToNil(input.smtpUser) {
            fields.append("\"smtp_user\":\(MVJSONLiteral.string(user))")
        }
        if let password = emptyToNil(input.smtpPassword) {
            fields.append("\"smtp_password\":\(MVJSONLiteral.string(password))")
        }
        fields.append("\"spam_enabled\":\(MVJSONLiteral.bool(input.spamEnabled))")
        fields.append("\"trash_retention_days\":\(MVJSONLiteral.optionalInt(trashRetentionDays))")
        fields.append("\"junk_retention_days\":\(MVJSONLiteral.optionalInt(junkRetentionDays))")
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    // MARK: - Field parsing

    private static func trimmedOrThrow(_ value: String, _ error: MVAccountFormError) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw error }
        return trimmed
    }

    private static func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalPort(_ value: String) throws -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let port = Int(trimmed), port > 0 else { throw MVAccountFormError.invalidSmtpPort }
        return port
    }

    /// `nil` is "Off" — PostIMAP's retention sweep never runs for this folder. A value below 1
    /// would clear the folder on the next tick (zero) or never run at all (negative), so both are
    /// rejected here the same way the backend's own `ge=1` constraint does.
    private static func optionalRetention(_ value: String, error: MVAccountFormError) throws -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let days = Int(trimmed), days >= 1 else { throw error }
        return days
    }
}
