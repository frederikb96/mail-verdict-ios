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
                prepare: prepareAccountDetail),
            MVScreenshotEntry(
                id: "account-edit-glacier",
                destination: .route(.account(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)),
                prepare: prepareAccountEditGlacier),
        ]

        /// The same account fixture as `account-detail`, plus opening its Edit… sheet and
        /// scrolling it to the Glacier section — the switch and days field sit below the fold in
        /// an ordinary Form, so nothing short of scrolling to them ever shows up in a screenshot.
        ///
        /// Each wait fails visibly (hangs, the same `neverReady()` shape `ReaderScreenshots` uses)
        /// rather than reporting the screen ready anyway: a stage this entry's own two flags never
        /// reach would otherwise pass silently as whatever the screen already looked like, which
        /// is exactly how the sheet not opening at all went unnoticed once already.
        @MainActor
        private static func prepareAccountEditGlacier(
            _ environment: AppEnvironment, _ connection: AppEnvironment.Connection
        ) async {
            await prepareAccountDetail(environment, connection)
            AccountsDebugServices.shared.showEditSheetRequested = true
            guard await poll({ AccountsDebugServices.shared.editSheetVisible ? true : nil }) != nil else {
                DebugLogBuffer.shared.append(.info, "screenshot", "account-edit-glacier: sheet never appeared")
                await neverReady()
                return
            }
            AccountsDebugServices.shared.scrollToGlacierSectionRequested = true
            guard await poll({ AccountsDebugServices.shared.glacierSectionScrolled ? true : nil }) != nil else {
                DebugLogBuffer.shared.append(
                    .info, "screenshot", "account-edit-glacier: never scrolled to the glacier section")
                await neverReady()
                return
            }
            // `scrollTo` schedules the scroll; it does not itself wait for the layout pass that
            // actually moves content on screen.
            try? await Task.sleep(for: .milliseconds(400))
        }

        /// A genuine timeout means the stage never reached the state it claims to — hanging here
        /// keeps `screenshotReady` from ever reporting this screen ready, so the sweep's own poll
        /// of `/screen/current` times out and fails the run honestly instead of publishing a
        /// screenshot of whatever was already on screen.
        private static func neverReady() async {
            while true { try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000) }
        }

        @MainActor
        private static func prepareAccountDetail(_: AppEnvironment, _: AppEnvironment.Connection) async {
            DebugLogBuffer.shared.append(.info, "screenshot", "account-detail: prepare start")
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
                     "emoji":"📧","spam_enabled":true,"trash_retention_days":30,"junk_retention_days":14,
                     "glacier_enabled":true,"glacier_folder_id":"22222222-2222-2222-2222-222222222222",
                     "glacier_auto_days":90}
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
            DebugLogBuffer.shared.append(.info, "screenshot", "account-detail: fixtures registered, polling for store")
            guard let store = await poll({ AccountsDebugServices.shared.activeAccountDetailStore }) else {
                DebugLogBuffer.shared.append(.info, "screenshot", "account-detail: store never appeared")
                return
            }
            DebugLogBuffer.shared.append(.info, "screenshot", "account-detail: store found, waiting for settle")
            await waitUntilSettled(
                label: "account-detail",
                isLoading: { store.state.isLoading },
                isFailed: {
                    if case .failed = store.state { return true }; return false
                },
                reload: { await store.load() })
            DebugLogBuffer.shared.append(.info, "screenshot", "account-detail: prepare end")
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

        /// Waits up to five seconds for `isLoading` to go false, then reloads once if the store
        /// settled into its failed state. Each probe runs through `MainActor.run` and reports a
        /// plain `Bool` rather than handing back the store's own load-state enum, since that enum
        /// carries an `Error` and isn't `Sendable`. `label` only feeds the temporary debug-log
        /// markers around the one unbounded step here (`reload`), so a hung sweep shows exactly
        /// which screen's reload never returned.
        @MainActor
        private static func waitUntilSettled(
            label: String,
            isLoading: @MainActor @Sendable () -> Bool,
            isFailed: @MainActor @Sendable () -> Bool,
            reload: @MainActor @Sendable () async -> Void
        ) async {
            for _ in 0..<100 {
                guard await MainActor.run(body: isLoading) else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if await MainActor.run(body: isFailed) {
                DebugLogBuffer.shared.append(.info, "screenshot", "\(label): settled failed, reloading")
                await reload()
                DebugLogBuffer.shared.append(.info, "screenshot", "\(label): reload returned")
            } else {
                DebugLogBuffer.shared.append(.info, "screenshot", "\(label): settled loaded")
            }
        }
    }

#endif
