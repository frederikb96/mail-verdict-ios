import Foundation
import MailVerdictKit
import PushEnvelope

public enum PushRegistrationFailure: Error, Equatable, Sendable {
    /// `GET /api/alerts/native-push` does not exist: the server predates native push.
    case serverTooOld
    /// The server has native push turned off, or cannot seal envelopes (no `ENCRYPTION_KEY`).
    case unavailable(reason: String?)
    /// The server's `push.apns_relay_urls` does not list the relay this app is built against.
    case relayNotAllowed
    case relay(PushRelayError)
    case server(String)
    case keychain(String)

    public var userMessage: String {
        switch self {
        case .serverTooOld: return "Update your MailVerdict server to enable notifications."
        case .unavailable(let reason):
            return reason.map { "This server has no push notifications configured yet: \($0)" }
                ?? "This server has no push notifications configured yet."
        case .relayNotAllowed: return "This server does not allow this app's push relay."
        case .relay(let error): return error.userMessage
        case .server(let detail): return detail
        case .keychain(let detail): return "The notification key could not be stored: \(detail)"
        }
    }
}

/// Registration with the relay and the server, end to end: ticket from the relay, the per-server
/// installation id and content key, and the upsert that hands both to the server.
public struct PushRegistrationService: Sendable {
    /// The relay this build is paired with. Only this app's publisher can sign pushes for its
    /// bundle id, so every MailVerdict server sends through this one address, and a server must
    /// list it in `push.apns_relay_urls` for this app to register there.
    public static let relayURL = "https://mailverdict-push.frederikberg.net"

    private let backend: any PushBackend
    private let relay: any PushRelayRegistering
    private let installations: any PushInstallationStoring
    private let relayURL: String
    private let now: @Sendable () -> Date

    public init(
        backend: any PushBackend, installations: any PushInstallationStoring,
        relay: (any PushRelayRegistering)? = nil, relayURL: String = PushRegistrationService.relayURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.installations = installations
        self.relay = relay ?? PushRelayClient(baseURL: URL(string: relayURL)!)
        self.relayURL = relayURL
        self.now = now
    }

    /// Whether this server can take a registration from this build at all.
    public static func checkAvailability(
        backend: any PushBackend, relayURL: String = PushRegistrationService.relayURL
    ) async throws -> NativePushConfigResponse {
        let config: NativePushConfigResponse
        do {
            config = try await backend.nativePushConfig()
        } catch {
            if (error as? MVError)?.statusCode == 404 { throw PushRegistrationFailure.serverTooOld }
            throw PushRegistrationFailure.server(error.mvUserMessage)
        }
        guard config.available else { throw PushRegistrationFailure.unavailable(reason: config.reason) }
        guard config.relayUrls.contains(relayURL) else { throw PushRegistrationFailure.relayNotAllowed }
        return config
    }

    /// Registers, or re-registers, and returns the record to store in place of `record`.
    ///
    /// The server upserts on the installation id, so this is safe to repeat. A first registration
    /// carries the chosen device name; a refresh sends none, leaving a name or a mute set from
    /// the web alone. Pending folder scope follows as a separate change, since a registration has
    /// no field for it.
    public func register(
        apnsToken: String, serverOrigin: String, record: PushRegistrationRecord
    ) async throws -> PushRegistrationRecord {
        _ = try await Self.checkAvailability(backend: backend, relayURL: relayURL)

        let ticket: PushTicket
        do {
            ticket = try await relay.register(apnsToken: apnsToken)
        } catch let error as PushRelayError {
            throw PushRegistrationFailure.relay(error)
        }

        let installation: PushInstallation
        do {
            if let existing = try installations.load(serverOrigin: serverOrigin) {
                installation = existing
            } else {
                installation = PushInstallation.generate()
                try installations.save(installation, serverOrigin: serverOrigin)
            }
        } catch {
            throw PushRegistrationFailure.keychain(error.mvUserMessage)
        }

        let isFirst = record.subscriptionId == nil
        let request = NativeSubscriptionCreate(
            installationId: installation.installationId, relayUrl: relayURL, ticket: ticket.ticket,
            contentKey: installation.contentKey.base64EncodedString(),
            label: isFirst ? record.pendingLabel : nil, mutedChannels: nil
        )
        let subscription: PushSubscriptionResponse
        do {
            subscription = try await backend.registerNative(request)
        } catch {
            throw PushRegistrationFailure.server(error.mvUserMessage)
        }

        var updated = record
        updated.subscriptionId = subscription.id
        updated.apnsToken = apnsToken
        updated.ticketExpiresAt = ticket.expiresAt
        updated.lastUpsertAt = now()
        updated.lastError = nil
        if isFirst { updated.pendingLabel = nil }
        if let folderIds = record.pendingFolderIds,
            (try? await backend.updateSubscription(id: subscription.id, .folderScope(folderIds))) != nil
        {
            updated.pendingFolderIds = nil
        }
        return updated
    }

    /// Removes this device from the server and forgets its key. Throws, leaving everything as it
    /// was, when the server cannot be told — dropping the key alone would leave the server pushing
    /// banners the phone can no longer open.
    public func unregister(serverOrigin: String, record: PushRegistrationRecord) async throws {
        if let subscriptionId = record.subscriptionId {
            do {
                try await backend.deleteSubscription(id: subscriptionId)
            } catch let error as MVError where error.statusCode == 404 {
                // Already gone — removed from another device, or dropped by the server itself.
            }
        }
        try installations.delete(serverOrigin: serverOrigin)
    }
}
