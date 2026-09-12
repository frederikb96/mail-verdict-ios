/// `GET/PUT /api/settings/{category}` — mirrors `mail_verdict.settings.defaults.SettingCategory`.
/// `calendar` is a real server category but out of scope here (Freddy's scope rules exclude
/// calendar management screens), so it is not exposed as a case an in-scope screen could reach
/// for — fetch it by its raw string if a future block genuinely needs it.
///
/// Each category's body is an untyped JSON object the server renders generically (see the UX
/// design's "generic category renderer") — `MVApiClient` returns the raw `Data` for these routes
/// rather than a typed model, and the order-preserving reader that turns it into a form is a
/// later block's own work.
public enum MVSettingsCategory: String, Sendable, Equatable, CaseIterable {
    case ai
    case retry
    case pipeline
    case semantic
    case outbox
    case mail
}
