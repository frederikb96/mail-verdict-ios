import Foundation

/// What this install has told one server about itself, and what it means to tell it next.
///
/// `isEnabled` is the person's own choice. A record that is not enabled is never registered or
/// refreshed, so turning notifications off stays off — the relay has nothing to unregister, and
/// the only way a server stops pushing is the phone ceasing to refresh its ticket there.
public struct PushRegistrationRecord: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// The server's row for this device, once registration has completed.
    public var subscriptionId: UUID?
    /// The APNs token the current ticket was issued for.
    public var apnsToken: String?
    public var ticketExpiresAt: Date?
    public var lastUpsertAt: Date?
    /// Folder scope chosen while the device had no row to hold it; `nil` is the arrival-folder
    /// default. Sent to the server as soon as a row exists.
    public var pendingFolderIds: [UUID]?
    /// Device name chosen while the device had no row to hold it.
    public var pendingLabel: String?
    /// Why the last registration attempt failed, kept until one succeeds.
    public var lastError: String?

    public init(
        isEnabled: Bool = false, subscriptionId: UUID? = nil, apnsToken: String? = nil,
        ticketExpiresAt: Date? = nil, lastUpsertAt: Date? = nil, pendingFolderIds: [UUID]? = nil,
        pendingLabel: String? = nil, lastError: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.subscriptionId = subscriptionId
        self.apnsToken = apnsToken
        self.ticketExpiresAt = ticketExpiresAt
        self.lastUpsertAt = lastUpsertAt
        self.pendingFolderIds = pendingFolderIds
        self.pendingLabel = pendingLabel
        self.lastError = lastError
    }

    public var isRegistered: Bool { isEnabled && subscriptionId != nil }
}

/// When an enabled device re-runs relay registration plus the server upsert. Launches, background
/// wakes and notification taps all ask; the answer is yes only when something actually changed or
/// aged, so an app opened fifty times a day registers about once.
public enum PushRefreshPolicy {
    /// Tickets live 90 days; renewing with 60 left leaves a month of ordinary launches to do it.
    public static let ticketRenewalWindow: TimeInterval = 60 * 24 * 3600
    /// The server stamps `last_seen_at` on every upsert, which is what its device list shows.
    public static let upsertInterval: TimeInterval = 24 * 3600

    public static func needsRefresh(_ record: PushRegistrationRecord, apnsToken: String, now: Date) -> Bool {
        guard record.isEnabled else { return false }
        guard record.subscriptionId != nil, let token = record.apnsToken, let expiresAt = record.ticketExpiresAt,
            let lastUpsertAt = record.lastUpsertAt
        else {
            return true
        }
        if token != apnsToken { return true }
        if expiresAt.timeIntervalSince(now) < ticketRenewalWindow { return true }
        if now.timeIntervalSince(lastUpsertAt) > upsertInterval { return true }
        return record.pendingFolderIds != nil
    }
}

/// One `PushRegistrationRecord` per server, in `UserDefaults` — nothing in it is secret; the
/// content key lives in the Keychain (`PushKeychain`).
// `@unchecked Sendable`: `UserDefaults` is thread-safe by Apple's own documentation, but
// swift-corelibs-foundation does not mark it `Sendable`.
public struct PushRecordStore: @unchecked Sendable {
    private static let keyPrefix = "mv.push.registration."
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(serverOrigin: String) -> PushRegistrationRecord? {
        guard let data = defaults.data(forKey: Self.keyPrefix + serverOrigin) else { return nil }
        return try? JSONDecoder().decode(PushRegistrationRecord.self, from: data)
    }

    public func save(_ record: PushRegistrationRecord, serverOrigin: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.keyPrefix + serverOrigin)
    }
}

public enum PushServerOrigin {
    /// `scheme://host[:port]`, lowercased — the one key a server's push state is filed under, so a
    /// trailing slash or a path on the configured URL never makes the same server look new.
    public static func origin(of backendURL: String) -> String? {
        guard let components = URLComponents(string: backendURL.trimmingCharacters(in: .whitespaces)),
            let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty
        else {
            return nil
        }
        return components.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}
