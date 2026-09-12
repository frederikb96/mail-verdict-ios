import Foundation
import MailVerdictKit

#if DEBUG

    /// Turns fixture mode on for this launch, if `-MVFixtureMode` asked for it.
    ///
    /// Two things have to happen before `RootView` is ever built, and both happen here rather
    /// than in `AppEnvironment` or `RootView` themselves, so neither needs to know fixture mode
    /// exists:
    /// - register the URL protocol that answers every request from the fixture table
    /// - plant a credential in the Keychain, so `AppEnvironment.init()` finds one already there
    ///   and connects on its own — exactly the path a real sign-in takes, just pre-seeded
    ///
    /// Reuses `MVKeychainCredentialStore` rather than writing to the Keychain independently: it is
    /// `internal` and this file compiles into the same app target, so the query attributes
    /// (service, account, `kSecAttrSynchronizable`) stay defined in exactly the one place that
    /// already owns them.
    enum FixtureBootstrap {
        /// Not a credential — nothing it authenticates ever leaves the process, since
        /// `MVFixtureURLProtocol` answers every request before it reaches the network. Only its
        /// presence matters: `AppEnvironment.init()` reads the Keychain and connects if it finds
        /// anything there.
        private static let placeholderCredential = MVAuthMode.bearer(token: "fixture-mode-token")

        static func installIfRequested() {
            guard MVFixtureLaunch.isEnabled() else { return }
            URLProtocol.registerClass(MVFixtureURLProtocol.self)
            MVKeychainCredentialStore().write(placeholderCredential)
        }
    }

#endif
