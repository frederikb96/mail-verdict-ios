#if DEBUG

    import MailVerdictKit
    import Observation

    /// The Account Detail screen's own equivalent of `SettingsDebugServices` — the store its
    /// screenshot `prepare` step waits on rather than sleeping a guessed duration.
    ///
    /// `@Observable`, not a plain class — `AccountDetailScreen`'s `.onChange(of:
    /// showEditSheetRequested)` needs the Observation framework to actually notice the flag
    /// changing after the view has already appeared. A plain `var` on an unobserved class is read
    /// once at render time and never revisited, which is exactly the shape that let
    /// `showEditSheetRequested` flip with nobody ever finding out: the flag *was* being set
    /// (`prepare` really did run this stage's own path), the view simply had no way to hear it.
    @Observable
    @MainActor
    final class AccountsDebugServices {
        static let shared = AccountsDebugServices()

        @ObservationIgnored weak var activeAccountDetailStore: MVAccountDetailStore?
        /// Flipped by a screenshot entry's `prepare` to open Account Detail's Edit… sheet with no
        /// touch available — `AccountDetailScreen`'s own `.onChange` is what actually presents it.
        var showEditSheetRequested = false
        /// Set once the Edit… sheet has actually appeared — `prepare` waits on this rather than a
        /// guessed duration, the same shape `MailListScreenshotStage.isOptionsSheetVisible` uses.
        var editSheetVisible = false
        /// Flipped by `prepare`, once the sheet is visible, to scroll the form to its Glacier
        /// section — the fields a screenshot of the plain top of the form would never show.
        var scrollToGlacierSectionRequested = false
        /// Set by `AccountFormView` once it has actually called `scrollTo` for that section.
        var glacierSectionScrolled = false

        private init() {}
    }

#endif
