import Foundation
import MailVerdictKit
import Observation

public enum PushAuthorization: Sendable, Equatable {
    case notDetermined, denied, authorized
}

/// The two channels a device can mute, in the order the web lists them.
public enum PushChannel: String, Sendable, CaseIterable {
    case mail, system

    public var title: String {
        switch self {
        case .mail: return "New Mail"
        case .system: return "System"
        }
    }
}

/// Everything the New Mail Notifications screen shows and does.
///
/// Registration itself completes outside this store: turning on asks the system for an APNs
/// token, and the app delegate carries it on to `PushRegistrationService` when it arrives, then
/// calls `reload()`. Everything else — status, device name, folder scope, other devices — is here.
@MainActor
@Observable
public final class NotificationSettingsStore {

    public enum Status: Equatable, Sendable {
        case loading
        /// The server could not be asked at all.
        case loadFailed(String)
        case serverTooOld
        case unavailable(reason: String?)
        case relayNotAllowed
        case notDetermined
        case denied
        /// Permission granted, notifications turned off for this server.
        case off
        case registering
        case registered
        /// The last registration attempt failed; turning on again retries it.
        case failed(String)
    }

    public struct Notice: Equatable, Sendable {
        public let text: String
        public let isError: Bool
    }

    /// What the store needs from outside, as plain values and closures, so a real run, a fixture
    /// run and a test all drive it the same way.
    public struct Dependencies: Sendable {
        public var backend: any PushBackend
        public var records: PushRecordStore
        public var serverOrigin: String
        public var authorization: @Sendable () async -> PushAuthorization
        public var requestAuthorization: @Sendable () async -> Bool
        /// Asks APNs for a token; the app registers once it arrives.
        public var beginRegistration: @MainActor @Sendable () -> Void
        public var unregister: @Sendable (PushRegistrationRecord) async throws -> Void
        public var relayURL: String

        public init(
            backend: any PushBackend, records: PushRecordStore, serverOrigin: String,
            authorization: @escaping @Sendable () async -> PushAuthorization,
            requestAuthorization: @escaping @Sendable () async -> Bool,
            beginRegistration: @escaping @MainActor @Sendable () -> Void,
            unregister: @escaping @Sendable (PushRegistrationRecord) async throws -> Void,
            relayURL: String = PushRegistrationService.relayURL
        ) {
            self.backend = backend
            self.records = records
            self.serverOrigin = serverOrigin
            self.authorization = authorization
            self.requestAuthorization = requestAuthorization
            self.beginRegistration = beginRegistration
            self.unregister = unregister
            self.relayURL = relayURL
        }
    }

    public private(set) var status: Status = .loading
    /// This device's own row, when it is registered and the server listed it.
    public private(set) var ownDevice: PushSubscriptionResponse?
    public private(set) var otherDevices: [PushSubscriptionResponse] = []
    public private(set) var groups: [PushFolderGroup] = []
    /// `nil` is the arrival-folder default.
    public private(set) var folderScope: [UUID]?
    /// Bound to the device-name field; `commitLabel()` saves it.
    public var label = ""
    /// Set by an action that has something to say; the screen shows it and clears it.
    public var notice: Notice?

    private let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    private var backend: any PushBackend { dependencies.backend }
    private var record: PushRegistrationRecord? {
        dependencies.records.load(serverOrigin: dependencies.serverOrigin)
    }

    private func save(_ record: PushRegistrationRecord) {
        dependencies.records.save(record, serverOrigin: dependencies.serverOrigin)
    }

    // MARK: Derived

    public func isFolderEnabled(_ folderId: UUID) -> Bool {
        PushFolderScope.enabledIds(scope: folderScope, groups: groups).contains(folderId)
    }

    public func isAccountEnabled(_ accountId: UUID) -> Bool {
        let enabled = PushFolderScope.enabledIds(scope: folderScope, groups: groups)
        return groups.first { $0.accountId == accountId }?.folders.contains { enabled.contains($0.id) } ?? false
    }

    public var allFoldersEnabled: Bool {
        PushFolderScope.allEnabled(scope: folderScope, groups: groups)
    }

    public func isChannelEnabled(_ channel: PushChannel) -> Bool {
        !(ownDevice?.mutedChannels.contains(channel.rawValue) ?? false)
    }

    // MARK: Loading

    /// Loads run concurrently — the screen's own, a registration finishing, a pull to refresh —
    /// and only the one started last is applied, so an early answer arriving late never
    /// overwrites a newer one.
    private var loadGeneration = 0

    public func reload() async {
        loadGeneration += 1
        let generation = loadGeneration

        var availability: PushRegistrationFailure?
        do {
            _ = try await PushRegistrationService.checkAvailability(
                backend: backend, relayURL: dependencies.relayURL)
        } catch let failure as PushRegistrationFailure {
            availability = failure
        } catch {
            availability = .server("\(error)")
        }
        let authorization = await dependencies.authorization()
        let subscriptions = (try? await backend.subscriptions()) ?? []
        var loadedGroups: [PushFolderGroup]?
        if let accounts = try? await backend.accounts() {
            var foldersByAccount: [UUID: [FolderResponse]] = [:]
            for account in accounts {
                foldersByAccount[account.id] = (try? await backend.folders(accountId: account.id)) ?? []
            }
            loadedGroups = PushFolderScope.groups(accounts: accounts, foldersByAccount: foldersByAccount)
        }

        guard generation == loadGeneration else { return }
        let record = self.record
        ownDevice = record?.isRegistered == true ? subscriptions.first { $0.id == record?.subscriptionId } : nil
        otherDevices = subscriptions.filter { $0.id != record?.subscriptionId }
        if let loadedGroups { groups = loadedGroups }

        if let ownDevice {
            folderScope = ownDevice.alertFolderIds
            label = ownDevice.label ?? ""
        } else {
            folderScope = record?.pendingFolderIds
            label = record?.pendingLabel ?? ""
        }
        status = Self.status(availability: availability, authorization: authorization, record: record)
    }

    /// The server's own refusals come first — asking for permission is pointless on a server that
    /// cannot send — then the system permission, then this device's own registration.
    static func status(
        availability: PushRegistrationFailure?, authorization: PushAuthorization, record: PushRegistrationRecord?
    ) -> Status {
        switch availability {
        case .serverTooOld: return .serverTooOld
        case .unavailable(let reason): return .unavailable(reason: reason)
        case .relayNotAllowed: return .relayNotAllowed
        case .some(let failure): return .loadFailed(failure.userMessage)
        case .none: break
        }
        switch authorization {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: break
        }
        guard let record, record.isEnabled else { return .off }
        if record.subscriptionId != nil { return .registered }
        if let error = record.lastError { return .failed(error) }
        return .registering
    }

    // MARK: Turning on and off

    /// The one place the system permission prompt is shown: a deliberate tap, never a launch.
    public func allow() async {
        guard await dependencies.requestAuthorization() else {
            status = .denied
            return
        }
        turnOn()
    }

    public func turnOn() {
        var record = self.record ?? PushRegistrationRecord()
        record.isEnabled = true
        record.lastError = nil
        if record.subscriptionId == nil {
            record.pendingFolderIds = folderScope
            record.pendingLabel = trimmedLabel
        }
        save(record)
        status = .registering
        dependencies.beginRegistration()
    }

    public func turnOff() async {
        guard var record = self.record, record.isEnabled else { return }
        do {
            try await dependencies.unregister(record)
        } catch {
            notice = Notice(text: "Could not turn notifications off: \(Self.describe(error))", isError: true)
            return
        }
        // The scope and name lived on the server row that is now gone; keep them for next time.
        record = PushRegistrationRecord(pendingFolderIds: folderScope, pendingLabel: trimmedLabel)
        save(record)
        ownDevice = nil
        status = .off
    }

    // MARK: Preferences

    public func toggleFolder(_ folderId: UUID, on: Bool) async {
        await setFolderScope(PushFolderScope.toggling(folderId, on: on, scope: folderScope, groups: groups))
    }

    public func setAccount(_ accountId: UUID, on: Bool) async {
        await setFolderScope(PushFolderScope.settingAccount(accountId, on: on, scope: folderScope, groups: groups))
    }

    public func toggleAll() async {
        await setFolderScope(PushFolderScope.togglingAll(scope: folderScope, groups: groups))
    }

    /// On the device's own row once there is one; kept locally until then and sent with the
    /// registration.
    func setFolderScope(_ scope: [UUID]?) async {
        let previous = folderScope
        folderScope = scope
        guard let deviceId = ownDevice?.id else {
            var record = self.record ?? PushRegistrationRecord()
            record.pendingFolderIds = scope
            save(record)
            return
        }
        do {
            let updated = try await backend.updateSubscription(id: deviceId, .folderScope(scope))
            ownDevice = updated
            folderScope = updated.alertFolderIds
        } catch {
            folderScope = previous
            notice = Notice(text: "Could not save the folders: \(Self.describe(error))", isError: true)
        }
    }

    public func commitLabel() async {
        let value = trimmedLabel
        guard let device = ownDevice else {
            var record = self.record ?? PushRegistrationRecord()
            record.pendingLabel = value
            save(record)
            return
        }
        guard device.label != value else { return }
        do {
            ownDevice = try await backend.updateSubscription(id: device.id, .label(value))
        } catch {
            label = device.label ?? ""
            notice = Notice(text: "Could not rename this device: \(Self.describe(error))", isError: true)
        }
    }

    public func setChannel(_ channel: PushChannel, enabled: Bool) async {
        guard let device = ownDevice else { return }
        var muted = Set(device.mutedChannels)
        if enabled { muted.remove(channel.rawValue) } else { muted.insert(channel.rawValue) }
        let ordered = PushChannel.allCases.map(\.rawValue).filter(muted.contains)
        do {
            ownDevice = try await backend.updateSubscription(id: device.id, .mutedChannels(ordered))
        } catch {
            notice = Notice(text: "Could not change the channel: \(Self.describe(error))", isError: true)
        }
    }

    public func remove(_ device: PushSubscriptionResponse) async {
        do {
            try await backend.deleteSubscription(id: device.id)
            otherDevices.removeAll { $0.id == device.id }
        } catch {
            notice = Notice(text: "Could not remove the device: \(Self.describe(error))", isError: true)
        }
    }

    public func sendTest() async {
        guard let deviceId = ownDevice?.id else { return }
        do {
            try await backend.sendTestPush(subscriptionId: deviceId)
            notice = Notice(text: "Test notification sent.", isError: false)
        } catch let error as MVError where error.statusCode == 410 {
            notice = Notice(
                text: "The push service no longer knows this iPhone. Turn notifications off and on again.",
                isError: true)
        } catch {
            notice = Notice(text: "The test notification was not sent: \(Self.describe(error))", isError: true)
        }
    }

    private var trimmedLabel: String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func describe(_ error: Error) -> String {
        (error as? MVError)?.userMessage ?? (error as? PushRegistrationFailure)?.userMessage ?? "\(error)"
    }
}
