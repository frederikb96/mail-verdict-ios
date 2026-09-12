import Foundation
import MailVerdictKit
import PushEnvelope
import XCTest

@testable import Push

// MARK: - Fakes

final class FakePushBackend: PushBackend, @unchecked Sendable {
    var config = NativePushConfigResponse(
        available: true, relayUrls: [PushRegistrationService.relayURL], reason: nil)
    var configError: Error?
    var subscriptionId = UUID()
    var registerRequests: [NativeSubscriptionCreate] = []
    var changes: [PushSubscriptionChange] = []
    var subscriptionsList: [PushSubscriptionResponse] = []
    var lookupRows: [AlertResponse] = []
    var lookupError: Error?
    var lookupRequests: [[UUID]] = []
    var badgeCount = 0
    var badgeRequests = 0
    var accountsList: [AccountResponse] = []
    var foldersByAccount: [UUID: [FolderResponse]] = [:]

    func nativePushConfig() async throws -> NativePushConfigResponse {
        if let configError { throw configError }
        return config
    }

    func registerNative(_ request: NativeSubscriptionCreate) async throws -> PushSubscriptionResponse {
        registerRequests.append(request)
        return Self.device(id: subscriptionId, label: request.label)
    }

    func subscriptions() async throws -> [PushSubscriptionResponse] { subscriptionsList }

    func updateSubscription(id: UUID, _ change: PushSubscriptionChange) async throws -> PushSubscriptionResponse {
        changes.append(change)
        let current = subscriptionsList.first { $0.id == id } ?? Self.device(id: id)
        switch change {
        case .folderScope(let ids): return Self.device(id: id, label: current.label, folders: ids)
        case .label(let label): return Self.device(id: id, label: label, folders: current.alertFolderIds)
        case .mutedChannels(let muted):
            return Self.device(id: id, label: current.label, folders: current.alertFolderIds, muted: muted)
        }
    }

    func deleteSubscription(id: UUID) async throws {}
    func sendTestPush(subscriptionId: UUID) async throws {}

    func lookupAlerts(ids: [UUID]) async throws -> [AlertResponse] {
        lookupRequests.append(ids)
        if let lookupError { throw lookupError }
        return lookupRows.filter { ids.contains($0.id) }
    }

    func badge(subscriptionId: UUID) async throws -> Int {
        badgeRequests += 1
        return badgeCount
    }

    func accounts() async throws -> [AccountResponse] { accountsList }
    func folders(accountId: UUID) async throws -> [FolderResponse] { foldersByAccount[accountId] ?? [] }
    func markRead(messageId: UUID) async throws {}

    static func device(
        id: UUID, label: String? = nil, folders: [UUID]? = nil, muted: [String] = []
    ) -> PushSubscriptionResponse {
        PushSubscriptionResponse(
            id: id, transport: .apns, label: label, alertFolderIds: folders, remindersEnabled: false,
            mutedChannels: muted, createdAt: Date(timeIntervalSince1970: 0), lastSeenAt: nil, failedAt: nil)
    }
}

final class FakeRelay: PushRelayRegistering, @unchecked Sendable {
    var calls = 0

    func register(apnsToken: String) async throws -> PushTicket {
        calls += 1
        return PushTicket(
            ticket: "ticket-\(calls)", ticketId: "0123456789abcdef",
            expiresAt: Date(timeIntervalSince1970: 1_797_000_000))
    }
}

final class FakeInstallations: PushInstallationStoring, @unchecked Sendable {
    var items: [String: PushInstallation] = [:]

    func load(serverOrigin: String) throws -> PushInstallation? { items[serverOrigin] }
    func save(_ installation: PushInstallation, serverOrigin: String) throws { items[serverOrigin] = installation }
    func delete(serverOrigin: String) throws { items[serverOrigin] = nil }
}

private func account(_ id: UUID, _ name: String) -> AccountResponse {
    AccountResponse(
        id: id, name: name, imapHost: "imap.example", imapPort: 993, imapUser: name, smtpHost: nil,
        smtpPort: nil, smtpUser: nil, stateError: nil, capabilities: nil,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), emoji: nil,
        folderOrder: nil, trashRetentionDays: nil, junkRetentionDays: nil)
}

private func folder(_ id: UUID, account: UUID, specialUse: String?, visible: Bool = true) -> FolderResponse {
    FolderResponse(
        id: id, accountId: account, imapName: id.uuidString, displayName: nil, specialUse: specialUse,
        mailboxId: nil, backfillTotal: nil, idleStatus: nil, lastSyncedAt: nil, syncError: nil, createdAt: nil,
        isVisible: visible)
}

/// Two accounts: the first with an inbox, a custom folder, Sent, Trash and a hidden folder; the
/// second with only an inbox.
private struct Mailboxes {
    let accountA = UUID(), accountB = UUID()
    let inboxA = UUID(), customA = UUID(), sentA = UUID(), trashA = UUID(), hiddenA = UUID(), inboxB = UUID()

    var accounts: [AccountResponse] { [account(accountA, "Work"), account(accountB, "Home")] }
    var foldersByAccount: [UUID: [FolderResponse]] {
        [
            accountA: [
                folder(inboxA, account: accountA, specialUse: "inbox"),
                folder(customA, account: accountA, specialUse: nil),
                folder(sentA, account: accountA, specialUse: "sent"),
                folder(trashA, account: accountA, specialUse: "trash"),
                folder(hiddenA, account: accountA, specialUse: nil, visible: false),
            ],
            accountB: [folder(inboxB, account: accountB, specialUse: "inbox")],
        ]
    }
    var groups: [PushFolderGroup] { PushFolderScope.groups(accounts: accounts, foldersByAccount: foldersByAccount) }
}

// MARK: - Registration

final class PushRegistrationServiceTests: XCTestCase {
    private let origin = "https://mail.example"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func service(_ backend: FakePushBackend, _ relay: FakeRelay, _ installations: FakeInstallations)
        -> PushRegistrationService
    {
        let now = self.now
        return PushRegistrationService(backend: backend, installations: installations, relay: relay, now: { now })
    }

    func testAFirstRegistrationHandsTheServerTheRelaysTicketAndThisInstallsOwnKey() async throws {
        let backend = FakePushBackend(), relay = FakeRelay(), installations = FakeInstallations()
        let scope = [UUID()]
        let record = PushRegistrationRecord(isEnabled: true, pendingFolderIds: scope, pendingLabel: "Work phone")

        let updated = try await service(backend, relay, installations)
            .register(apnsToken: "abcd", serverOrigin: origin, record: record)

        let sent = try XCTUnwrap(backend.registerRequests.first)
        let stored = try XCTUnwrap(installations.items[origin])
        XCTAssertEqual(sent.ticket, "ticket-1")
        XCTAssertEqual(sent.relayUrl, PushRegistrationService.relayURL)
        XCTAssertEqual(sent.installationId, stored.installationId)
        XCTAssertEqual(Data(base64Encoded: sent.contentKey), stored.contentKey)
        XCTAssertEqual(stored.contentKey.count, 32)
        XCTAssertEqual(sent.label, "Work phone")
        XCTAssertEqual(backend.changes, [.folderScope(scope)])
        XCTAssertEqual(updated.subscriptionId, backend.subscriptionId)
        XCTAssertEqual(updated.apnsToken, "abcd")
        XCTAssertEqual(updated.ticketExpiresAt, Date(timeIntervalSince1970: 1_797_000_000))
        XCTAssertEqual(updated.lastUpsertAt, now)
        XCTAssertNil(updated.pendingFolderIds)
        XCTAssertNil(updated.pendingLabel)
    }

    func testARefreshKeepsTheInstallationAndLeavesTheServersNameAlone() async throws {
        let backend = FakePushBackend(), relay = FakeRelay(), installations = FakeInstallations()
        let subject = service(backend, relay, installations)
        let first = try await subject.register(
            apnsToken: "abcd", serverOrigin: origin,
            record: PushRegistrationRecord(isEnabled: true, pendingLabel: "Work phone"))
        _ = try await subject.register(apnsToken: "ef01", serverOrigin: origin, record: first)

        XCTAssertEqual(backend.registerRequests.count, 2)
        XCTAssertEqual(backend.registerRequests[1].installationId, backend.registerRequests[0].installationId)
        XCTAssertEqual(backend.registerRequests[1].contentKey, backend.registerRequests[0].contentKey)
        XCTAssertNil(backend.registerRequests[1].label)
        XCTAssertNil(backend.registerRequests[1].mutedChannels)
    }

    func testARelayTheServerDoesNotListIsNeverAsked() async {
        let backend = FakePushBackend(), relay = FakeRelay()
        backend.config = NativePushConfigResponse(available: true, relayUrls: ["https://other.example"], reason: nil)
        do {
            _ = try await service(backend, relay, FakeInstallations())
                .register(apnsToken: "abcd", serverOrigin: origin, record: PushRegistrationRecord(isEnabled: true))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? PushRegistrationFailure, .relayNotAllowed)
        }
        XCTAssertEqual(relay.calls, 0)
    }

    func testAServerWithoutTheNativePushEndpointIsTooOld() async {
        let backend = FakePushBackend()
        backend.configError = MVError.detail("Not Found", statusCode: 404)
        do {
            _ = try await service(backend, FakeRelay(), FakeInstallations())
                .register(apnsToken: "abcd", serverOrigin: origin, record: PushRegistrationRecord(isEnabled: true))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? PushRegistrationFailure, .serverTooOld)
        }
    }
}

final class PushRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(expiresInDays days: Double, upsertedHoursAgo hours: Double, token: String = "abcd")
        -> PushRegistrationRecord
    {
        PushRegistrationRecord(
            isEnabled: true, subscriptionId: UUID(), apnsToken: token,
            ticketExpiresAt: now.addingTimeInterval(days * 86_400),
            lastUpsertAt: now.addingTimeInterval(-hours * 3_600))
    }

    func testARecentRegistrationIsLeftAlone() {
        XCTAssertFalse(
            PushRefreshPolicy.needsRefresh(record(expiresInDays: 61, upsertedHoursAgo: 23), apnsToken: "abcd", now: now)
        )
    }

    func testARotatedTokenRegistersAgain() {
        XCTAssertTrue(
            PushRefreshPolicy.needsRefresh(
                record(expiresInDays: 89, upsertedHoursAgo: 1, token: "old"), apnsToken: "abcd", now: now))
    }

    func testATicketWithUnderSixtyDaysLeftIsRenewed() {
        XCTAssertTrue(
            PushRefreshPolicy.needsRefresh(record(expiresInDays: 59, upsertedHoursAgo: 1), apnsToken: "abcd", now: now))
    }

    func testTheServerHearsFromTheDeviceAtLeastDaily() {
        XCTAssertTrue(
            PushRefreshPolicy.needsRefresh(record(expiresInDays: 89, upsertedHoursAgo: 25), apnsToken: "abcd", now: now)
        )
    }

    func testNotificationsTurnedOffNeverRegister() {
        XCTAssertFalse(PushRefreshPolicy.needsRefresh(PushRegistrationRecord(), apnsToken: "abcd", now: now))
    }
}

final class PushServerOriginTests: XCTestCase {
    func testTheSameServerWrittenTwoWaysIsOneOrigin() {
        XCTAssertEqual(PushServerOrigin.origin(of: "https://Mail.Example/"), "https://mail.example")
        XCTAssertEqual(PushServerOrigin.origin(of: " https://mail.example/app "), "https://mail.example")
        XCTAssertEqual(PushServerOrigin.origin(of: "http://10.0.0.5:8000"), "http://10.0.0.5:8000")
        XCTAssertNil(PushServerOrigin.origin(of: "not a url"))
    }
}

// MARK: - Clearing

final class PushReconcilerTests: XCTestCase {

    private func alert(_ id: UUID, dismissed: Bool) -> AlertResponse {
        AlertResponse(
            id: id, kind: "mail", title: "Subject", body: "Sender", url: nil, accountId: nil, messageId: nil,
            folderId: nil, deliveredAt: nil, dismissedAt: dismissed ? Date(timeIntervalSince1970: 1) : nil,
            createdAt: Date(timeIntervalSince1970: 0))
    }

    func testWithdrawsWhatWasDismissedOrDeletedAndKeepsWhatIsStillOpen() async {
        let backend = FakePushBackend()
        let open = UUID(), dismissed = UUID(), deleted = UUID()
        backend.lookupRows = [alert(open, dismissed: false), alert(dismissed, dismissed: true)]
        backend.badgeCount = 4

        let outcome = await PushReconciler(backend: backend).reconcile(
            delivered: [
                DeliveredNotification(identifier: "a", alertId: open),
                DeliveredNotification(identifier: "b", alertId: dismissed),
                DeliveredNotification(identifier: "c", alertId: deleted),
            ],
            subscriptionId: UUID())

        XCTAssertEqual(Set(outcome.identifiersToRemove), ["b", "c"])
        XCTAssertEqual(outcome.badge, 4)
    }

    func testAnUnreachableServerWithdrawsNothing() async {
        let backend = FakePushBackend()
        backend.lookupError = MVError.transport("offline")
        let outcome = await PushReconciler(backend: backend).reconcile(
            delivered: [DeliveredNotification(identifier: "a", alertId: UUID())], subscriptionId: nil)
        XCTAssertEqual(backend.lookupRequests.count, 1)
        XCTAssertEqual(outcome.identifiersToRemove, [])
    }

    func testLooksUpInBatchesTheServerAccepts() async {
        let backend = FakePushBackend()
        let delivered = (0..<201).map { _ in DeliveredNotification(identifier: UUID().uuidString, alertId: UUID()) }
        _ = await PushReconciler(backend: backend).reconcile(delivered: delivered, subscriptionId: nil)
        XCTAssertEqual(backend.lookupRequests.map(\.count).sorted(), [1, 200])
    }

    func testWithoutARegistrationTheBadgeIsLeftAlone() async {
        let backend = FakePushBackend()
        let outcome = await PushReconciler(backend: backend).reconcile(delivered: [], subscriptionId: nil)
        XCTAssertNil(outcome.badge)
        XCTAssertEqual(backend.badgeRequests, 0)
    }
}

// MARK: - Folder scope

final class PushFolderScopeTests: XCTestCase {
    private let boxes = Mailboxes()

    func testTheDefaultIsTheVisibleFoldersMailArrivesIn() {
        XCTAssertEqual(PushFolderScope.defaultIds(boxes.groups), [boxes.inboxA, boxes.customA, boxes.inboxB])
    }

    func testTickingBackToTheDefaultCollapsesToTheDefault() {
        let without = PushFolderScope.toggling(boxes.customA, on: false, scope: nil, groups: boxes.groups)
        XCTAssertEqual(without, [boxes.inboxA, boxes.inboxB])
        XCTAssertNil(PushFolderScope.toggling(boxes.customA, on: true, scope: without, groups: boxes.groups))
    }

    func testTickingAnOutgoingFolderIsAnExplicitChoice() {
        XCTAssertEqual(
            PushFolderScope.toggling(boxes.sentA, on: true, scope: nil, groups: boxes.groups),
            [boxes.inboxA, boxes.customA, boxes.sentA, boxes.inboxB])
    }

    func testSelectAllThenDeselectAll() {
        let all = PushFolderScope.togglingAll(scope: nil, groups: boxes.groups)
        XCTAssertEqual(all, [boxes.inboxA, boxes.customA, boxes.sentA, boxes.trashA, boxes.inboxB])
        XCTAssertEqual(PushFolderScope.togglingAll(scope: all, groups: boxes.groups), [])
    }

    func testTurningAnAccountOffClearsOnlyItsFolders() {
        let off = PushFolderScope.settingAccount(boxes.accountA, on: false, scope: nil, groups: boxes.groups)
        XCTAssertEqual(off, [boxes.inboxB])
        XCTAssertNil(PushFolderScope.settingAccount(boxes.accountA, on: true, scope: off, groups: boxes.groups))
    }
}

// MARK: - Settings screen

@MainActor
final class NotificationSettingsStoreTests: XCTestCase {
    private let origin = "https://mail.example"
    private let boxes = Mailboxes()

    private func makeStore(
        _ backend: FakePushBackend, records: PushRecordStore, authorization: PushAuthorization = .authorized,
        onBegin: @escaping @MainActor @Sendable () -> Void = {}
    ) -> NotificationSettingsStore {
        backend.accountsList = boxes.accounts
        backend.foldersByAccount = boxes.foldersByAccount
        return NotificationSettingsStore(
            dependencies: .init(
                backend: backend, records: records, serverOrigin: origin,
                authorization: { authorization }, requestAuthorization: { true },
                beginRegistration: onBegin, unregister: { _ in }))
    }

    private func freshRecords() -> PushRecordStore {
        PushRecordStore(defaults: UserDefaults(suiteName: "push-tests-\(UUID().uuidString)")!)
    }

    func testAServerThatCannotSendOutranksTheSystemPermission() async {
        XCTAssertEqual(
            NotificationSettingsStore.status(
                availability: .unavailable(reason: "no key"), authorization: .denied, record: nil),
            .unavailable(reason: "no key"))
        XCTAssertEqual(
            NotificationSettingsStore.status(availability: nil, authorization: .denied, record: nil), .denied)
        XCTAssertEqual(
            NotificationSettingsStore.status(
                availability: nil, authorization: .authorized,
                record: PushRegistrationRecord(isEnabled: true, lastError: "relay down")),
            .failed("relay down"))
    }

    func testAFolderChoiceBeforeRegistrationStaysOnTheDevice() async {
        let backend = FakePushBackend(), records = freshRecords()
        let store = makeStore(backend, records: records)
        await store.reload()
        XCTAssertEqual(store.status, .off)

        await store.toggleFolder(boxes.customA, on: false)

        XCTAssertEqual(backend.changes, [])
        XCTAssertEqual(records.load(serverOrigin: origin)?.pendingFolderIds, [boxes.inboxA, boxes.inboxB])
    }

    func testReturningToTheDefaultOnARegisteredDeviceSendsItExplicitly() async {
        let backend = FakePushBackend(), records = freshRecords()
        let deviceId = UUID()
        backend.subscriptionsList = [FakePushBackend.device(id: deviceId, folders: [boxes.inboxA, boxes.inboxB])]
        records.save(PushRegistrationRecord(isEnabled: true, subscriptionId: deviceId), serverOrigin: origin)
        let store = makeStore(backend, records: records)
        await store.reload()
        XCTAssertEqual(store.status, .registered)

        await store.toggleFolder(boxes.customA, on: true)

        XCTAssertEqual(backend.changes, [.folderScope(nil)])
        XCTAssertNil(store.folderScope)
    }

    func testTurningOnKeepsTheChoicesForTheRegistrationAndAsksForAToken() async {
        let backend = FakePushBackend(), records = freshRecords()
        var began = 0
        let store = makeStore(backend, records: records, onBegin: { began += 1 })
        await store.reload()
        store.label = "  Work phone "
        await store.toggleFolder(boxes.sentA, on: true)

        store.turnOn()

        let record = records.load(serverOrigin: origin)
        XCTAssertEqual(began, 1)
        XCTAssertEqual(store.status, .registering)
        XCTAssertEqual(record?.isEnabled, true)
        XCTAssertEqual(record?.pendingLabel, "Work phone")
        XCTAssertEqual(record?.pendingFolderIds, [boxes.inboxA, boxes.customA, boxes.sentA, boxes.inboxB])
    }
}

// MARK: - Routing

final class PushRoutingTests: XCTestCase {

    func testATapOpensTheMessageOrTheScreenThatExplainsTheAlert() {
        let messageId = UUID()
        XCTAssertEqual(
            PushTapTarget(userInfo: ["kind": "mail", "message_id": messageId.uuidString.lowercased()]),
            .message(messageId))
        XCTAssertEqual(PushTapTarget(userInfo: ["kind": "mail"]), .mailboxes)
        XCTAssertEqual(PushTapTarget(userInfo: ["kind": "outbox_stalled"]), .notifications)
    }

    func testNoBannerForTheMessageAlreadyBeingRead() {
        let messageId = UUID()
        let scope = ListScope.folder(accountId: UUID(), folderId: UUID())
        let list = Route.list(scope, aroundMessageId: nil)
        let reading = [list, .reader(ReaderContext(source: .list(scope), messageId: messageId))]
        XCTAssertFalse(PushPresentation.shouldPresent(messageId: messageId, navigationPath: reading))
        XCTAssertTrue(PushPresentation.shouldPresent(messageId: UUID(), navigationPath: reading))
        XCTAssertTrue(PushPresentation.shouldPresent(messageId: messageId, navigationPath: [list]))
    }
}
