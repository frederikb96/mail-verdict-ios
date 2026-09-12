#if DEBUG

    import MailVerdictKit

    /// The Account Detail screen's own equivalent of `SettingsDebugServices` — the store its
    /// screenshot `prepare` step waits on rather than sleeping a guessed duration.
    @MainActor
    final class AccountsDebugServices {
        static let shared = AccountsDebugServices()

        weak var activeAccountDetailStore: MVAccountDetailStore?

        private init() {}
    }

#endif
