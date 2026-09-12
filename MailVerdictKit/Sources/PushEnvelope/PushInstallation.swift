import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// This install's identity towards one server: the id bound into every envelope's AAD and the
/// content key the server seals with. Created once per server, on the device, and handed to that
/// server only — the push relay never sees either.
public struct PushInstallation: Codable, Sendable, Equatable {
    public let installationId: UUID
    public let contentKey: Data

    public init(installationId: UUID, contentKey: Data) {
        self.installationId = installationId
        self.contentKey = contentKey
    }

    /// A fresh random id and a 256-bit key from the platform's secure random source.
    public static func generate() -> PushInstallation {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return PushInstallation(installationId: UUID(), contentKey: key)
    }

    enum CodingKeys: String, CodingKey {
        case installationId = "installation_id", contentKey = "content_key"
    }
}
