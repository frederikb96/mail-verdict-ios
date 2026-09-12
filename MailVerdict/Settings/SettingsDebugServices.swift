#if DEBUG

    import MailVerdictKit

    /// What the Mac sweep's screenshot `prepare` step needs to reach past fixture registration:
    /// the store each Settings screen is actually loading into, so it can wait for that load to
    /// settle instead of guessing how long it takes. Each screen sets its own property the moment
    /// it creates its store, in its own `.task`, before calling `load()`.
    @MainActor
    final class SettingsDebugServices {
        static let shared = SettingsDebugServices()

        weak var activeAccountOrderStore: MVAccountOrderStore?
        weak var activeSettingsCategoryStore: MVSettingsCategoryStore?
        weak var activeUnifiedSetupStore: MVUnifiedSetupStore?

        private init() {}
    }

#endif
