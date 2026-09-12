import Foundation
import MailVerdictKit
import Security

/// Where the backend's credential lives — none, a bearer token, or a basic-auth username and
/// password (systems design §5.01's three auth modes), encoded as JSON so one Keychain item
/// holds whichever of the three this install actually uses.
///
/// The Keychain is the only place on the device holding a secret; everything else the app
/// remembers (the backend URL) is an ordinary preference and lives in `UserDefaults`.
///
/// Not in `MailVerdictKit` because `Security` is Apple-only, and one unguarded import there would
/// drag the whole test suite onto a metered runner.
struct MVKeychainCredentialStore {

    #if DEBUG
        /// Fixture mode's credential, held in memory because the Keychain is not always available.
        ///
        /// A simulator build made with `CODE_SIGNING_ALLOWED=NO` has no keychain-access-group
        /// entitlement, and `SecItemAdd` refuses with `errSecMissingEntitlement`. A signed build
        /// — every build that reaches a device — is unaffected, so this exists only so a Mac
        /// workflow run can get past the connection gate.
        ///
        /// Deliberately not a general fallback: it is consulted only when fixture mode asked for
        /// it, so a real build can never silently keep a credential outside the Keychain.
        nonisolated(unsafe) private static var fixtureCredential: MVAuthMode?
        private static let fixtureLock = NSLock()
    #endif

    private let service: String
    private let account = "backend-credential"

    init(service: String = Bundle.main.bundleIdentifier ?? "com.frederikberg.mailverdict") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Explicit, not inherited. This is a personal device credential for one backend and
            // has no business syncing to Freddy's other hardware through iCloud Keychain.
            kSecAttrSynchronizable as String: false,
        ]
    }

    func read() -> MVAuthMode? {
        #if DEBUG
            if MVFixtureLaunch.isEnabled() {
                Self.fixtureLock.lock()
                defer { Self.fixtureLock.unlock() }
                if let mode = Self.fixtureCredential { return mode }
            }
        #endif
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let mode = try? JSONDecoder().decode(MVAuthMode.self, from: data),
            !isEffectivelyEmpty(mode)
        else {
            return nil
        }
        return mode
    }

    /// Writing `nil` removes the item. `.none` is a complete, deliberate choice (a LAN install
    /// with no proxy in front of it) and is never treated as absent; an empty bearer token or an
    /// empty basic-auth pair is, since the sign-in form never submits one on purpose — only a
    /// stale or cleared value could reach here looking like that.
    @discardableResult
    func write(_ mode: MVAuthMode?) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)

        guard let mode, !isEffectivelyEmpty(mode), let data = try? JSONEncoder().encode(mode) else {
            return true
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        // Survives a relaunch and works while the phone is locked but has been unlocked once,
        // which is what a background refresh needs.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        #if DEBUG
            if status != errSecSuccess, MVFixtureLaunch.isEnabled() {
                Self.fixtureLock.lock()
                Self.fixtureCredential = mode
                Self.fixtureLock.unlock()
                return true
            }
        #endif
        return status == errSecSuccess
    }

    private func isEffectivelyEmpty(_ mode: MVAuthMode) -> Bool {
        switch mode {
        case .none: return false
        case .bearer(let token): return token.isEmpty
        case .basic(let username, let password): return username.isEmpty && password.isEmpty
        }
    }
}
