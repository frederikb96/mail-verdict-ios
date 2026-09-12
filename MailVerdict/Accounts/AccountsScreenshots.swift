import Foundation
import MailVerdictKit

#if DEBUG

    /// Accounts' own screenshot entries — Account Detail, for the one account also named in
    /// `SettingsScreenshots`' own fixtures (same id, because the two files never run in the same
    /// process launch — each `-MVFixtureScreen <id>` is its own relaunch).
    ///
    /// `prepare` registers only what Account Detail itself calls (the single-account GET and its
    /// sync status), and only for this entry — see `SettingsScreenshots`' own doc comment for why
    /// that has to happen in `prepare` rather than at `entries`' evaluation. It then waits for
    /// `AccountsDebugServices`' store to settle, with one reload if the first attempt failed,
    /// rather than guessing how long that takes.
    enum AccountsScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(
                id: "account-detail",
                destination: .route(.account(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)),
                prepare: prepareAccountDetail)
        ]

        @MainActor
        private static func prepareAccountDetail(_: AppEnvironment, _: AppEnvironment.Connection) async {
            MVFixtureURLProtocol.register(
                method: "GET", path: "/api/accounts/11111111-1111-1111-1111-111111111111"
            ) {
                Data(
                    #"""
                    {"id":"11111111-1111-1111-1111-111111111111","name":"Posteo",
                     "imap_host":"posteo.de","imap_port":993,"imap_user":"me@posteo.de",
                     "smtp_host":"posteo.de","smtp_port":587,"smtp_user":"me@posteo.de",
                     "is_active":true,"state":"active","state_error":null,
                     "created_at":"2025-01-10T08:00:00+00:00","updated_at":"2026-01-15T10:30:00+00:00",
                     "emoji":"📧","spam_enabled":true,"trash_retention_days":30,"junk_retention_days":14}
                    """#.utf8)
            }
            MVFixtureURLProtocol.register(
                method: "GET",
                path: "/api/accounts/11111111-1111-1111-1111-111111111111/sync-status"
            ) {
                Data(
                    #"""
                    {"account_id":"11111111-1111-1111-1111-111111111111","state":"active",
                     "state_error":null,"last_full_sync":"2026-01-15T10:00:00+00:00",
                     "last_incr_sync":"2026-01-15T10:29:00+00:00","sync_tier":"qresync",
                     "folders_synced":5,"folders_total":5,"messages_synced":1234,
                     "error_count":0,"last_error":null,"updated_at":"2026-01-15T10:29:00+00:00"}
                    """#.utf8)
            }
            guard let store = await poll({ AccountsDebugServices.shared.activeAccountDetailStore }) else { return }
            _ = await poll { store.state.isLoading ? nil : true }
            if case .failed = store.state { await store.load() }
        }

        /// Up to five seconds, checked every 50 ms.
        @MainActor
        private static func poll<Value>(_ probe: @MainActor () -> Value?) async -> Value? {
            for _ in 0..<100 {
                if let value = probe() { return value }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
    }

#endif
