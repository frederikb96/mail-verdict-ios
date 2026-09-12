import Foundation
import XCTest

@testable import PushEnvelope

/// The server's own fixed vector (`tests/fixtures/push_envelope_v1.json` in mail-verdict), copied
/// byte for byte. Agreement with it is the only proof the two sides share one wire format — a
/// round trip on either side alone passes with any layout at all.
final class PushEnvelopeVectorTests: XCTestCase {

    private struct Vector: Decodable {
        let contentKeyBase64: String
        let installationId: UUID
        let nonceHex: String
        let plaintext: String
        let blob: String

        enum CodingKeys: String, CodingKey {
            case contentKeyBase64 = "content_key_base64", installationId = "installation_id",
                nonceHex = "nonce_hex", plaintext, blob
        }

        var key: Data { Data(base64Encoded: contentKeyBase64)! }
        var nonce: Data {
            var bytes: [UInt8] = []
            var index = nonceHex.startIndex
            while index < nonceHex.endIndex {
                let next = nonceHex.index(index, offsetBy: 2)
                bytes.append(UInt8(nonceHex[index..<next], radix: 16)!)
                index = next
            }
            return Data(bytes)
        }
    }

    private static func loadVector() throws -> Vector {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/push_envelope_v1.json")
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    func testOpensTheServersBlobToItsExactPlaintext() throws {
        let vector = try Self.loadVector()
        let opened = try PushEnvelope.open(blob: vector.blob, key: vector.key, installationId: vector.installationId)
        XCTAssertEqual(opened, Data(vector.plaintext.utf8))
    }

    func testSealsToTheServersExactBlobGivenTheSameNonce() throws {
        let vector = try Self.loadVector()
        let sealed = try PushEnvelope.seal(
            Data(vector.plaintext.utf8), key: vector.key, installationId: vector.installationId, nonce: vector.nonce)
        XCTAssertEqual(sealed, vector.blob)
    }

    func testDecodesTheVectorsPayload() throws {
        let vector = try Self.loadVector()
        let payload = try PushEnvelope.openPayload(
            blob: vector.blob, key: vector.key, installationId: vector.installationId)
        XCTAssertEqual(payload.kind, "mail")
        XCTAssertEqual(payload.title, "Grüße aus Aachen")
        XCTAssertEqual(payload.body, "Anna Schmidt <anna@example.com>")
        XCTAssertEqual(payload.badge, 3)
        XCTAssertEqual(payload.resolved, [UUID(uuidString: "19a8b7c6-d5e4-4f3a-8b2c-1d0e9f8a7b6c")!])
    }

    func testRefusesTheBlobUnderAnotherInstallationId() throws {
        let vector = try Self.loadVector()
        XCTAssertThrowsError(try PushEnvelope.open(blob: vector.blob, key: vector.key, installationId: UUID())) {
            XCTAssertEqual($0 as? PushEnvelopeError, .authenticationFailed)
        }
    }

    func testRefusesATamperedCiphertext() throws {
        let vector = try Self.loadVector()
        var raw = [UInt8](Data(base64Encoded: vector.blob)!)
        raw[20] ^= 0x01
        let tampered = Data(raw).base64EncodedString()
        XCTAssertThrowsError(
            try PushEnvelope.open(blob: tampered, key: vector.key, installationId: vector.installationId)
        ) {
            XCTAssertEqual($0 as? PushEnvelopeError, .authenticationFailed)
        }
    }

    func testRefusesAnUnknownVersion() throws {
        let vector = try Self.loadVector()
        var raw = [UInt8](Data(base64Encoded: vector.blob)!)
        raw[0] = 2
        XCTAssertThrowsError(
            try PushEnvelope.open(
                blob: Data(raw).base64EncodedString(), key: vector.key, installationId: vector.installationId)
        ) {
            XCTAssertEqual($0 as? PushEnvelopeError, .unknownVersion)
        }
    }
}

final class PushBannerTests: XCTestCase {

    private func payload(kind: String, title: String, body: String?, messageId: UUID? = UUID()) -> PushPayload {
        let json: [String: Any?] = [
            "v": 1, "alert_id": "8D1E6C52-4B0A-4F3E-A2C9-5E7F10B2D3A4", "kind": kind, "title": title, "body": body,
            "account_id": "0b7d9e21-6c4f-4a8b-b1d2-3e4f5a6b7c8d", "message_id": messageId?.uuidString,
            "folder_id": nil, "url": nil, "badge": 7, "resolved": [String](),
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.mapValues { $0 ?? NSNull() })
        return try! JSONDecoder().decode(PushPayload.self, from: data)
    }

    func testAMailBannerLeadsWithTheSenderNameAndCarriesTheSubjectAsItsBody() {
        let banner = PushBanner(
            payload: payload(kind: "mail", title: "Invoice", body: "\"Anna Schmidt\" <anna@example.com>"))
        XCTAssertEqual(banner.title, "Anna Schmidt")
        XCTAssertEqual(banner.body, "Invoice")
        XCTAssertEqual(banner.categoryIdentifier, PushNotificationKeys.mailCategory)
        XCTAssertEqual(banner.threadIdentifier, "0b7d9e21-6c4f-4a8b-b1d2-3e4f5a6b7c8d")
        XCTAssertEqual(banner.badge, 7)
        // Lowercased, so the app's lookups match the server's ids whatever case they were sent in.
        XCTAssertEqual(banner.userInfo[PushNotificationKeys.alertId], "8d1e6c52-4b0a-4f3e-a2c9-5e7f10b2d3a4")
    }

    func testABareAddressIsTheSenderAsItIs() {
        XCTAssertEqual(PushBanner.senderName("<anna@example.com>"), "anna@example.com")
        XCTAssertEqual(PushBanner.senderName("anna@example.com"), "anna@example.com")
    }

    func testAMailAlertWithoutAMessageOffersNoMarkAsRead() {
        let banner = PushBanner(payload: payload(kind: "mail", title: "Invoice", body: "Anna", messageId: nil))
        XCTAssertNil(banner.categoryIdentifier)
    }

    func testASystemAlertKeepsItsOwnTitleAndBody() {
        let banner = PushBanner(payload: payload(kind: "outbox_stalled", title: "Sending stalled", body: "3 messages"))
        XCTAssertEqual(banner.title, "Sending stalled")
        XCTAssertEqual(banner.body, "3 messages")
        XCTAssertNil(banner.categoryIdentifier)
    }
}

final class PushClearingTests: XCTestCase {

    func testWithdrawsOnlyNotificationsWhoseAlertIsStale() {
        let stale = UUID(), live = UUID()
        let delivered = [
            DeliveredNotification(identifier: "a", alertId: stale),
            DeliveredNotification(identifier: "b", alertId: live),
            DeliveredNotification(identifier: "c", alertId: nil),
        ]
        XCTAssertEqual(PushClearing.identifiersToRemove(from: delivered, isStale: { $0 == stale }), ["a"])
    }

    func testAnUnopenedPushIsRecognisedByItsCollapseIdentifier() {
        let alertId = UUID()
        let unopened = DeliveredNotification(identifier: alertId.uuidString.lowercased(), userInfo: [:])
        XCTAssertEqual(unopened.alertId, alertId)
    }

    func testFindsTheBlobWhereTheRelayNestsIt() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["mutable-content": 1], "mv": ["v": 1, "b": "AQID"] as [String: Any],
        ]
        XCTAssertEqual(PushEnvelope.blob(fromUserInfo: userInfo), "AQID")
    }
}
