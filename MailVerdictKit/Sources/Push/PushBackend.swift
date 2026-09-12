import Foundation
import MailVerdictKit
import PushEnvelope

/// One change to this device's own row. Folder scope `nil` is the arrival-folder default, which
/// the server only applies when it is sent as an explicit null — an omitted field is left alone.
public enum PushSubscriptionChange: Sendable, Equatable {
    case folderScope([UUID]?)
    case label(String?)
    case mutedChannels([String])
}

/// The MailVerdict endpoints push needs, as one seam: `MVApiClient` in the app, a fake in tests.
public protocol PushBackend: Sendable {
    func nativePushConfig() async throws -> NativePushConfigResponse
    func registerNative(_ request: NativeSubscriptionCreate) async throws -> PushSubscriptionResponse
    func subscriptions() async throws -> [PushSubscriptionResponse]
    func updateSubscription(id: UUID, _ change: PushSubscriptionChange) async throws -> PushSubscriptionResponse
    func deleteSubscription(id: UUID) async throws
    func sendTestPush(subscriptionId: UUID) async throws
    func lookupAlerts(ids: [UUID]) async throws -> [AlertResponse]
    func badge(subscriptionId: UUID) async throws -> Int
    func accounts() async throws -> [AccountResponse]
    func folders(accountId: UUID) async throws -> [FolderResponse]
    func markRead(messageId: UUID) async throws
}

extension MVApiClient: PushBackend {
    public func nativePushConfig() async throws -> NativePushConfigResponse {
        try await getNativePushConfig()
    }

    public func registerNative(_ request: NativeSubscriptionCreate) async throws -> PushSubscriptionResponse {
        try await registerNativePushSubscription(request)
    }

    public func subscriptions() async throws -> [PushSubscriptionResponse] {
        try await listPushSubscriptions()
    }

    public func updateSubscription(id: UUID, _ change: PushSubscriptionChange) async throws
        -> PushSubscriptionResponse
    {
        let update: PushSubscriptionUpdate
        switch change {
        case .folderScope(let ids): update = PushSubscriptionUpdate(alertFolderIds: .some(ids))
        case .label(let label): update = PushSubscriptionUpdate(label: label)
        case .mutedChannels(let channels): update = PushSubscriptionUpdate(mutedChannels: channels)
        }
        return try await updatePushSubscription(id: id, update)
    }

    public func deleteSubscription(id: UUID) async throws {
        try await deletePushSubscription(id: id)
    }

    public func sendTestPush(subscriptionId: UUID) async throws {
        try await testPushSubscription(id: subscriptionId)
    }

    public func badge(subscriptionId: UUID) async throws -> Int {
        try await getAlertBadge(subscriptionId: subscriptionId).count
    }

    public func accounts() async throws -> [AccountResponse] {
        try await listAccounts()
    }

    public func folders(accountId: UUID) async throws -> [FolderResponse] {
        try await listFolders(accountId: accountId)
    }

    public func markRead(messageId: UUID) async throws {
        _ = try await performMessageAction(messageId: messageId, action: .markRead)
    }
}

extension MVError {
    /// The HTTP status behind a server error, when there was one.
    var statusCode: Int? {
        switch self {
        case .detail(_, let statusCode), .http(let statusCode, _): return statusCode
        case .transport, .decoding, .proxyRequiresBrowserLogin: return nil
        }
    }
}

/// Where this install keeps each server's `PushInstallation`.
public protocol PushInstallationStoring: Sendable {
    func load(serverOrigin: String) throws -> PushInstallation?
    func save(_ installation: PushInstallation, serverOrigin: String) throws
    func delete(serverOrigin: String) throws
}

#if canImport(Security)
    /// The Keychain group the notification service extension reads from.
    public struct PushKeychainInstallationStore: PushInstallationStoring {
        public init() {}

        public func load(serverOrigin: String) throws -> PushInstallation? {
            try PushKeychain.load(serverOrigin: serverOrigin)
        }

        public func save(_ installation: PushInstallation, serverOrigin: String) throws {
            try PushKeychain.save(installation, serverOrigin: serverOrigin)
        }

        public func delete(serverOrigin: String) throws {
            try PushKeychain.delete(serverOrigin: serverOrigin)
        }
    }
#endif
