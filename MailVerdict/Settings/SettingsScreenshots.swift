import MailVerdictKit

#if DEBUG

    /// Settings' own screenshot entries: the top-level screen, and one generic category form
    /// (`ai`, since it is also the one carrying the provider-key section).
    ///
    /// `entries`' own initializer is where the fixture routes these screens call get registered —
    /// `ScreenshotRegistry.all` forces every feature's `entries` to evaluate the moment fixture
    /// mode looks up its first entry (`RootView`'s own navigation trigger, before any destination
    /// screen exists to fetch anything), so by the time this screen's `.task` actually runs the
    /// route table already has an answer for it.
    enum SettingsScreenshots {
        static let entries: [MVScreenshotEntry] = {
            registerFixtures()
            return [
                MVScreenshotEntry(id: "settings-main", destination: .route(.settings)),
                MVScreenshotEntry(
                    id: "settings-category-ai",
                    destination: .route(.settingsCategory(MVSettingsCategory.ai.rawValue))),
            ]
        }()

        private static func registerFixtures() {
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
            MVFixtureURLProtocol.register(method: "GET", path: "/api/account-order") {
                Data(
                    #"{"order":["11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"]}"#
                        .utf8)
            }
            MVFixtureURLProtocol.register(method: "GET", path: "/api/settings/ai") {
                Data(
                    #"""
                    {"id":"1","category":"ai","provider":"anthropic","model":"claude-sonnet-5",
                     "reasoning_effort":"medium","max_tokens":4096,"max_retries":3,
                     "anthropic_api_key_configured":true,"anthropic_api_key_hint":"abcd",
                     "openai_api_key_configured":false,"openai_api_key_hint":null}
                    """#.utf8)
            }
        }
    }

#endif
