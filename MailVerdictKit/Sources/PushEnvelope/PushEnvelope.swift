import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// Why a blob did not open. Every case means the same thing to the notification extension — show
/// the relay's generic banner unchanged — and they are told apart only so a test can say which
/// check refused.
public enum PushEnvelopeError: Error, Equatable, Sendable {
    case badKeyLength
    case notBase64
    case unknownVersion
    case truncated
    case authenticationFailed
    case malformedPayload
}

/// The sealed blob a native push carries, opened on the device with a content key the push relay
/// never sees.
///
/// Version 1, as the server's `push/envelope.py` seals it:
/// `base64(0x01 || nonce (12 bytes) || AES-256-GCM ciphertext || tag (16 bytes))`, authenticated
/// against `"mv-push-v1:" + installation id` in its lowercase hyphenated form. Binding the
/// installation id in means a blob sealed for one install never opens on another, even under the
/// same key.
public enum PushEnvelope {
    public static let version: UInt8 = 1
    public static let contentKeyLength = 32
    static let nonceLength = 12
    static let tagLength = 16

    public static func open(blob: String, key: Data, installationId: UUID) throws -> Data {
        guard key.count == contentKeyLength else { throw PushEnvelopeError.badKeyLength }
        guard let raw = Data(base64Encoded: blob) else { throw PushEnvelopeError.notBase64 }
        // Copied into an array so the slicing below is zero-based whatever `Data` was handed in.
        let bytes = [UInt8](raw)
        guard let first = bytes.first else { throw PushEnvelopeError.truncated }
        guard first == version else { throw PushEnvelopeError.unknownVersion }
        guard bytes.count >= 1 + nonceLength + tagLength else { throw PushEnvelopeError.truncated }

        let nonce = Data(bytes[1..<(1 + nonceLength)])
        let ciphertext = Data(bytes[(1 + nonceLength)..<(bytes.count - tagLength)])
        let tag = Data(bytes[(bytes.count - tagLength)...])
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad(installationId))
        } catch {
            throw PushEnvelopeError.authenticationFailed
        }
    }

    /// Opens a blob and decodes the alert it carries.
    public static func openPayload(blob: String, key: Data, installationId: UUID) throws -> PushPayload {
        let plaintext = try open(blob: blob, key: key, installationId: installationId)
        guard let payload = try? JSONDecoder().decode(PushPayload.self, from: plaintext),
            payload.v == Int(version)
        else {
            throw PushEnvelopeError.malformedPayload
        }
        return payload
    }

    /// The blob inside an APNs payload, which the relay nests as `{"mv": {"v": 1, "b": <blob>}}`.
    public static func blob(fromUserInfo userInfo: [AnyHashable: Any]) -> String? {
        (userInfo[PushNotificationKeys.envelope] as? [String: Any])?[PushNotificationKeys.blob] as? String
    }

    /// Only the server seals in production; this exists so the fixed test vector can be checked in
    /// both directions, which is what pins the byte layout rather than merely a round trip.
    static func seal(_ plaintext: Data, key: Data, installationId: UUID, nonce: Data? = nil) throws -> String {
        guard key.count == contentKeyLength else { throw PushEnvelopeError.badKeyLength }
        let gcmNonce = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(
            plaintext, using: SymmetricKey(data: key), nonce: gcmNonce, authenticating: aad(installationId))
        var raw = Data([version])
        raw.append(contentsOf: Array(gcmNonce))
        raw.append(box.ciphertext)
        raw.append(box.tag)
        return raw.base64EncodedString()
    }

    static func aad(_ installationId: UUID) -> Data {
        Data("mv-push-v1:\(installationId.uuidString.lowercased())".utf8)
    }
}
