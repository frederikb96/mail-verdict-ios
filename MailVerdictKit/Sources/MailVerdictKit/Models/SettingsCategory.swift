/// `GET/PUT /api/settings/{category}` — mirrors `mail_verdict.settings.defaults.SettingCategory`.
/// `calendar` is a real server category but out of scope here (calendar management screens are
/// not part of this app), so it is not exposed as a case an in-scope screen could reach for —
/// fetch it by its raw string if something genuinely needs it.
///
/// Each category's body is an untyped JSON object the server renders generically as a form —
/// `MVApiClient` returns the raw `Data` for these routes rather than a typed model, and turning
/// it into an order-preserving form is a screen's own work.
public enum MVSettingsCategory: String, Sendable, Equatable, CaseIterable {
    case ai
    case retry
    case pipeline
    case semantic
    case outbox
    case mail
}
