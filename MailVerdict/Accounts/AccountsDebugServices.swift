#if DEBUG

    import MailVerdictKit

    /// The Account Detail screen's own equivalent of `SettingsDebugServices` — the store its
    /// screenshot `prepare` step waits on rather than sleeping a guessed duration.
    @MainActor
    final class AccountsDebugServices {
        static let shared = AccountsDebugServices()

        weak var activeAccountDetailStore: MVAccountDetailStore?
        /// Flipped by a screenshot entry's `prepare` to open Account Detail's Edit… sheet with no
        /// touch available — `AccountDetailScreen`'s own `.onChange` is what actually presents it.
        var showEditSheetRequested = false
        /// Set once the Edit… sheet has actually appeared — `prepare` waits on this rather than a
        /// guessed duration, the same shape `MailListScreenshotStage.isOptionsSheetVisible` uses.
        var editSheetVisible = false

        private init() {}
    }

#endif
