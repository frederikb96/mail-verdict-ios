import Foundation
import MailVerdictKit
import Security

/// Where the backend's bearer token lives.
///
/// The Keychain is the only place on the device holding a secret; everything else the app
/// remembers (the backend URL) is an ordinary preference and lives in `UserDefaults`.
///
/// Not in `MailVerdictKit` because `Security` is Apple-only, and one unguarded import there would
/// drag the whole test suite onto a metered runner.
struct MVKeychainTokenStore {

    #if DEBUG
        /// Fixture mode's token, held in memory because the Keychain is not always available.
        ///
        /// A simulator build made with `CODE_SIGNING_ALLOWED=NO` has no keychain-access-group
        /// entitlement, and `SecItemAdd` refuses with `errSecMissingEntitlement`. A signed build
        /// — every build that reaches a device — is unaffected, so this exists only so a Mac
        /// workflow run can get past the connection gate.
        ///
        /// Deliberately not a general fallback: it is consulted only when fixture mode asked for
        /// it, so a real build can never silently keep a credential outside the Keychain.
        nonisolated(unsafe) private static var fixtureToken: String?
        private static let fixtureLock = NSLock()
    #endif

    private let service: String
    private let account = "backend-token"

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

    func read() -> String? {
        #if DEBUG
            if MVFixtureLaunch.isEnabled() {
                Self.fixtureLock.lock()
                defer { Self.fixtureLock.unlock() }
                if let token = Self.fixtureToken { return token }
            }
        #endif
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else {
            return nil
        }
        return token
    }

    /// Writing `nil` removes the item.
    ///
    /// Delete-then-add rather than `SecItemUpdate`: an update against a missing item fails, and
    /// branching on which case applies is a second code path for no benefit.
    @discardableResult
    func write(_ token: String?) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)

        guard let token, !token.isEmpty else { return true }

        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        // Survives a relaunch and works while the phone is locked but has been unlocked once,
        // which is what a background refresh needs.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        #if DEBUG
            if status != errSecSuccess, MVFixtureLaunch.isEnabled() {
                Self.fixtureLock.lock()
                Self.fixtureToken = token
                Self.fixtureLock.unlock()
                return true
            }
        #endif
        return status == errSecSuccess
    }
}
