import Foundation
import MailVerdictKit

#if DEBUG

    /// Settings' own screenshot entries: the top-level screen, one generic category form (`ai`,
    /// since it is also the one carrying the provider-key section), and Unified Views setup.
    ///
    /// Each entry's `prepare` registers only the fixture routes *that screen* calls, never at
    /// `entries`' own evaluation — `ScreenshotRegistry.all` forces every feature's `entries` to
    /// evaluate together the moment fixture mode looks up the target id, so registering routes
    /// there would answer another feature's request to the same path (`/api/accounts`, most
    /// concretely) in every single-screen launch, not only this one's. `prepare` runs only for
    /// the matching entry, and only once the destination screen already exists — which may
    /// already have started loading against an empty route table, so `prepare` waits for
    /// `SettingsDebugServices`' matching store to settle (one reload if the first attempt failed)
    /// rather than guessing how long that takes.
    enum SettingsScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(id: "settings-main", destination: .route(.settings), prepare: prepareSettingsMain),
            MVScreenshotEntry(
                id: "settings-category-ai",
                destination: .route(.settingsCategory(MVSettingsCategory.ai.rawValue)),
                prepare: prepareSettingsCategoryAI),
            MVScreenshotEntry(
                id: "unified-views", destination: .route(.unifiedViews), prepare: prepareUnifiedViews),
        ]

        private static func prepareSettingsMain(_: AppEnvironment, _: AppEnvironment.Connection) async {
            registerAccountsFixture()
            registerAccountOrderFixture()
            guard let store = await poll({ SettingsDebugServices.shared.activeAccountOrderStore }) else { return }
            _ = await poll { store.state == .loading ? nil : true }
            if case .failed = store.state { await store.load() }
        }

        private static func prepareSettingsCategoryAI(_: AppEnvironment, _: AppEnvironment.Connection) async {
            MVFixtureURLProtocol.register(method: "GET", path: "/api/settings/ai") {
                Data(
                    #"""
                    {"id":"1","category":"ai","provider":"anthropic","model":"claude-sonnet-5",
                     "reasoning_effort":"medium","max_tokens":4096,"max_retries":3,
                     "anthropic_api_key_configured":true,"anthropic_api_key_hint":"abcd",
                     "openai_api_key_configured":false,"openai_api_key_hint":null}
                    """#.utf8)
            }
            guard let store = await poll({ SettingsDebugServices.shared.activeSettingsCategoryStore }) else { return }
            _ = await poll { store.state == .loading ? nil : true }
            if case .failed = store.state { await store.load() }
        }

        private static func prepareUnifiedViews(_: AppEnvironment, _: AppEnvironment.Connection) async {
            registerAccountsFixture()
            MVFixtureURLProtocol.register(method: "GET", path: "/api/unified/folders") {
                Data(
                    #"""
                    [{"id":"33333333-3333-3333-3333-333333333333","unified_name":"Everything","emoji":"📥",
                      "folders":[{"account_id":"11111111-1111-1111-1111-111111111111","account_name":"Posteo",
                                  "account_emoji":"📧","folder_id":"44444444-4444-4444-4444-444444444444",
                                  "imap_name":"INBOX","special_use":"inbox"}],
                      "unread_count":3,"total_count":120}]
                    """#.utf8)
            }
            MVFixtureURLProtocol.register(
                method: "GET", path: "/api/accounts/11111111-1111-1111-1111-111111111111/folders"
            ) {
                Data(
                    #"""
                    [{"id":"44444444-4444-4444-4444-444444444444",
                      "account_id":"11111111-1111-1111-1111-111111111111","imap_name":"INBOX",
                      "display_name":null,"special_use":"inbox","mailbox_id":null,
                      "initial_sync_done":true,"backfill_total":null,"idle_requested":true,
                      "idle_status":"idle","last_synced_at":"2026-01-15T10:29:00+00:00",
                      "sync_error":null,"created_at":"2025-01-10T08:00:00+00:00","unread_count":3,
                      "total_count":120,"is_visible":true,
                      "unified_view_ids":["33333333-3333-3333-3333-333333333333"]}]
                    """#.utf8)
            }
            MVFixtureURLProtocol.register(
                method: "GET", path: "/api/accounts/22222222-2222-2222-2222-222222222222/folders"
            ) {
                Data("[]".utf8)
            }
            guard let store = await poll({ SettingsDebugServices.shared.activeUnifiedSetupStore }) else { return }
            _ = await poll { store.state == .loading ? nil : true }
            if case .failed = store.state { await store.load() }
        }

        /// Two accounts, shared by every entry here that lists accounts at all — kept as one
        /// function so the same fixture data reads the same way wherever it shows up.
        private static func registerAccountsFixture() {
            MVFixtureURLProtocol.register(method: "GET", path: "/api/accounts") {
                Data(
                    #"""
                    [
                      {"id":"11111111-1111-1111-1111-111111111111","name":"Posteo",
                       "imap_host":"posteo.de","imap_port":993,"imap_user":"me@posteo.de",
                       "is_active":true,"state":"active","state_error":null,
                       "created_at":"2025-01-10T08:00:00+00:00","updated_at":"2026-01-15T10:30:00+00:00",
                       "emoji":"📧","spam_enabled":true,"trash_retention_days":30,"junk_retention_days":14},
                      {"id":"22222222-2222-2222-2222-222222222222","name":"Work",
                       "imap_host":"imap.work.example","imap_port":993,"imap_user":"me@work.example",
                       "is_active":true,"state":"active","state_error":null,
                       "created_at":"2025-03-01T08:00:00+00:00","updated_at":"2026-01-15T10:30:00+00:00",
                       "emoji":"💼","spam_enabled":false,"trash_retention_days":null,"junk_retention_days":null}
                    ]
                    """#.utf8)
            }
        }

        private static func registerAccountOrderFixture() {
            MVFixtureURLProtocol.register(method: "GET", path: "/api/account-order") {
                Data(
                    #"{"order":["11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"]}"#
                        .utf8)
            }
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
