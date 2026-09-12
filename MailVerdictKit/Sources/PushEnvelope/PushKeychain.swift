#if canImport(Security)
    import Foundation
    import Security

    /// Where each server's `PushInstallation` lives: the Keychain access group the app and the
    /// notification service extension share, one item per server origin.
    ///
    /// Readable after first unlock and while locked, because the extension runs exactly then — an
    /// item stored with the default `WhenUnlocked` fails silently from a locked phone and every
    /// banner falls back to generic text. Never synchronised: the key belongs to this install.
    ///
    /// Both targets' entitlements must list the same group, or every read here returns nothing
    /// with no error to notice.
    public enum PushKeychain {

        /// The resolved group — the entitlements file's `$(AppIdentifierPrefix)` becomes the team
        /// id at build time, but a query needs the literal string.
        public static let accessGroup = "CSHG4AV9YH.com.frederikberg.mailverdict"
        static let service = "mailverdict.push"

        public struct KeychainError: Error, Sendable {
            public let status: OSStatus
        }

        public static func load(serverOrigin: String) throws -> PushInstallation? {
            var query = baseQuery()
            query[kSecAttrAccount as String] = serverOrigin
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
            return (result as? Data).flatMap { try? JSONDecoder().decode(PushInstallation.self, from: $0) }
        }

        /// Every server's installation. The extension does not know which server a push came
        /// from, so it tries each until one opens the blob — there is normally exactly one.
        public static func loadAll() throws -> [PushInstallation] {
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
            let items = (result as? [Data]) ?? []
            return items.compactMap { try? JSONDecoder().decode(PushInstallation.self, from: $0) }
        }

        public static func save(_ installation: PushInstallation, serverOrigin: String) throws {
            var query = baseQuery()
            query[kSecAttrAccount as String] = serverOrigin
            // Delete-then-add: one code path whether or not an item exists, since an update fails
            // outright when there is nothing to update.
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = try JSONEncoder().encode(installation)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }

        public static func delete(serverOrigin: String) throws {
            var query = baseQuery()
            query[kSecAttrAccount as String] = serverOrigin
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
        }

        private static func baseQuery() -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: false,
            ]
        }
    }
#endif
