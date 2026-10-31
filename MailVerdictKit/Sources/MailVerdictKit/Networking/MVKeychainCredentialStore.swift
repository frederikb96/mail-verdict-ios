#if canImport(Security)
    import Foundation
    import Security

    /// Where the backend's credential lives — none, a bearer token, or a basic-auth username and
    /// password, encoded as JSON so one Keychain item holds whichever of the three this install
    /// actually uses.
    ///
    /// The Keychain is the only place on the device holding a secret; everything else the app
    /// remembers (the backend URL) is an ordinary preference and lives in `UserDefaults`. The URL
    /// is also published here, in the same access group, because the share extension cannot see
    /// the app's `UserDefaults`: the app writes it, the extension only reads.
    ///
    /// Guarded by `canImport(Security)` because the package also builds on Linux, where one
    /// unguarded import would drag the whole test suite onto a metered runner.
    public struct MVKeychainCredentialStore: Sendable {

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

        /// The app's bundle identifier, which names the Keychain service and the access group. A
        /// constant rather than `Bundle.main.bundleIdentifier` because the share extension reads
        /// the same items under its own bundle identifier.
        public static let appBundleIdentifier = "com.frederikberg.mailverdict"

        private let service: String
        private let credentialAccount = "backend-credential"
        private let backendURLAccount = "backend-url"

        public init(service: String = MVKeychainCredentialStore.appBundleIdentifier) {
            self.service = service
        }

        private func baseQuery(account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                // This app's own group, explicit rather than left to default — the entitlements list
                // a second group now (the one shared with the push extension), and an unspecified
                // access group is no longer guaranteed to resolve to this one. It is the same literal
                // an existing item already carries (it was the only group before the split), so
                // pinning it does not strand anything already written. The share extension holds this
                // group too, which is how it reads the credential without a second copy.
                kSecAttrAccessGroup as String: "\(Self.teamId).\(service)",
                // Explicit, not inherited. This is a personal device credential for one backend and
                // has no business syncing to other hardware through iCloud Keychain.
                kSecAttrSynchronizable as String: false,
            ]
        }

        /// The literal team id `$(AppIdentifierPrefix)` resolves to at build time — a Keychain query
        /// needs the resolved string, never the build variable.
        private static let teamId = "CSHG4AV9YH"

        public func read() -> MVAuthMode? {
            #if DEBUG
                if MVFixtureLaunch.isEnabled() {
                    Self.fixtureLock.lock()
                    defer { Self.fixtureLock.unlock() }
                    if let mode = Self.fixtureCredential { return mode }
                }
            #endif
            guard let data = readItem(account: credentialAccount),
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
        public func write(_ mode: MVAuthMode?) -> Bool {
            guard let mode, !isEffectivelyEmpty(mode), let data = try? JSONEncoder().encode(mode) else {
                removeItem(account: credentialAccount)
                return true
            }

            let status = writeItem(data, account: credentialAccount)
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

        /// The backend address the app is signed in to, as the app last published it. `nil` when
        /// the app has not connected since the share extension was added, or has signed out.
        public func readBackendURL() -> String? {
            guard let data = readItem(account: backendURLAccount),
                let url = String(data: data, encoding: .utf8), !url.isEmpty
            else { return nil }
            return url
        }

        /// A client for the connection the app signed in with, for code running outside the app's
        /// own connection: the share extension, and the Shortcuts app asking for a list to pick
        /// from. `nil` when signed out.
        public func signedInClient() -> MVApiClient? {
            guard let url = readBackendURL(), let mode = read(),
                let factory = try? MVRequestFactory(baseURL: url, authProvider: { mode })
            else { return nil }
            return MVApiClient(requestFactory: factory)
        }

        /// Publishes the backend address for the share extension; `nil` removes it. The app's own
        /// copy stays in `UserDefaults`, so a failed write here costs the extension its address and
        /// nothing else.
        public func writeBackendURL(_ url: String?) {
            guard let url, !url.isEmpty else {
                removeItem(account: backendURLAccount)
                return
            }
            _ = writeItem(Data(url.utf8), account: backendURLAccount)
        }

        private func readItem(account: String) -> Data? {
            var query = baseQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
            return item as? Data
        }

        private func removeItem(account: String) {
            SecItemDelete(baseQuery(account: account) as CFDictionary)
        }

        private func writeItem(_ data: Data, account: String) -> OSStatus {
            removeItem(account: account)
            var query = baseQuery(account: account)
            query[kSecValueData as String] = data
            // Survives a relaunch and works while the phone is locked but has been unlocked once,
            // which is what a background refresh needs. `ThisDeviceOnly` because this is a personal
            // device credential for one self-hosted backend — it has no business migrating through
            // an encrypted backup restore to a different phone, the way the bare `AfterFirstUnlock`
            // form does.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil)
        }

        private func isEffectivelyEmpty(_ mode: MVAuthMode) -> Bool {
            switch mode {
            case .none: return false
            case .bearer(let token): return token.isEmpty
            case .basic(let username, let password): return username.isEmpty && password.isEmpty
            }
        }
    }
#endif
