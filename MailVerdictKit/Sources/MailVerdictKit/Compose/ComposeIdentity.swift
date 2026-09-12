import Foundation

/// One address the From menu offers: a real sending identity, or — for an account that has none
/// — a stand-in for the address it sends with anyway (`imap_user`, the server's own fallback).
/// The stand-in has no `identityId` and must never be sent as `identity_id`, since it names no
/// row that exists.
public struct ComposeFromAddress: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let accountId: UUID
    public let identityId: UUID?
    public let address: String
    public let displayName: String?
    public let isDefault: Bool

    /// "Name <address>", or the bare address. The address is never dropped: several identities
    /// sharing one display name are told apart only by it.
    public var label: String {
        guard let displayName, !displayName.isEmpty else { return address }
        return "\(displayName) <\(address)>"
    }
}

/// Port of the web's `matchIdentity` (`lib/identities.ts`) and `compose-dialog.tsx`'s
/// `pickableAddresses`/`defaultAddressForAccount`.
public enum ComposeIdentityRules {

    /// The identity one of `addresses` names, trying them in order — so a caller passing To before
    /// Cc prefers a direct match. Case-insensitive, since header casing means nothing.
    public static func matchIdentity(_ addresses: [String?], in identities: [IdentityResponse]) -> UUID? {
        guard !identities.isEmpty else { return nil }
        var byAddress: [String: UUID] = [:]
        for identity in identities where byAddress[identity.address.lowercased()] == nil {
            byAddress[identity.address.lowercased()] = identity.id
        }
        for address in addresses {
            guard let address, !address.isEmpty else { continue }
            if let match = byAddress[extractEmail(address).lowercased()] { return match }
        }
        return nil
    }

    public static func pickableAddresses(
        accounts: [AccountResponse], identities: [IdentityResponse]
    ) -> [ComposeFromAddress] {
        accounts.flatMap { account -> [ComposeFromAddress] in
            let own = identities.filter { $0.accountId == account.id }
            guard !own.isEmpty else {
                return [
                    ComposeFromAddress(
                        key: "account-default:\(account.id.uuidString)", accountId: account.id, identityId: nil,
                        address: account.imapUser, displayName: nil, isDefault: true)
                ]
            }
            return own.map {
                ComposeFromAddress(
                    key: $0.id.uuidString, accountId: account.id, identityId: $0.id, address: $0.address,
                    displayName: $0.displayName, isDefault: $0.isDefault)
            }
        }
    }

    /// The account's default address — its starred identity, or its first address.
    public static func defaultAddress(in addresses: [ComposeFromAddress], accountId: UUID?) -> ComposeFromAddress? {
        guard let accountId else { return nil }
        let forAccount = addresses.filter { $0.accountId == accountId }
        return forAccount.first(where: \.isDefault) ?? forAccount.first
    }

    /// The first preferred account that has an address wins; failing all of them, the first
    /// address at all.
    public static func resolve(
        in addresses: [ComposeFromAddress], preferring accountIds: [UUID?]
    ) -> ComposeFromAddress? {
        for accountId in accountIds {
            if let found = defaultAddress(in: addresses, accountId: accountId) { return found }
        }
        return addresses.first
    }
}
