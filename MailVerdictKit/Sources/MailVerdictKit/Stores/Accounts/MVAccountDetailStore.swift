import Foundation
import Observation

/// One account's detail screen: status, sync toggle, the read-only server details, emoji, and the
/// destructive actions (sync now, edit, delete). The three sub-screens (folder order, image
/// exceptions, identities) are each their own store.
@Observable
@MainActor
public final class MVAccountDetailStore {
    public enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public let accountId: UUID
    public private(set) var account: AccountResponse?
    public private(set) var syncStatus: SyncStatusResponse?
    public private(set) var state: LoadState = .loading

    private let apiClient: MVApiClient

    public init(accountId: UUID, apiClient: MVApiClient) {
        self.accountId = accountId
        self.apiClient = apiClient
    }

    public var connectionState: MVAccountConnectionState {
        guard let account else { return .ok }
        return .classify(state: account.state, lastFullSync: syncStatus?.lastFullSync != nil)
    }

    public func load() async {
        state = .loading
        do {
            account = try await apiClient.getAccount(id: accountId)
            syncStatus = try? await apiClient.getSyncStatus(accountId: accountId)
            state = .loaded
        } catch {
            state = .failed((error as? MVError)?.userMessage ?? "\(error)")
        }
    }

    public func setActive(_ isActive: Bool) async throws {
        guard let previous = account else { return }
        account = AccountResponse(
            id: previous.id, name: previous.name, imapHost: previous.imapHost,
            imapPort: previous.imapPort, imapUser: previous.imapUser, smtpHost: previous.smtpHost,
            smtpPort: previous.smtpPort, smtpUser: previous.smtpUser, isActive: isActive,
            state: previous.state, stateError: previous.stateError,
            capabilities: previous.capabilities, createdAt: previous.createdAt,
            updatedAt: previous.updatedAt, emoji: previous.emoji, spamEnabled: previous.spamEnabled,
            folderOrder: previous.folderOrder, trashRetentionDays: previous.trashRetentionDays,
            junkRetentionDays: previous.junkRetentionDays
        )
        do {
            _ = try await apiClient.updateAccount(id: accountId, AccountUpdateRequest(isActive: isActive))
        } catch {
            account = previous
            throw error
        }
    }

    public func setEmoji(_ emoji: String?) async throws {
        try await apiClient.setAccountEmoji(accountId: accountId, emoji: emoji)
        await load()
    }

    public func triggerSync() async throws {
        try await apiClient.triggerSync(accountId: accountId)
    }

    public func update(_ input: MVAccountFormInput) async throws {
        let request = try MVAccountFormModel.buildUpdateRequest(input)
        account = try await apiClient.updateAccount(id: accountId, request)
    }

    public func delete() async throws {
        try await apiClient.deleteAccount(id: accountId)
    }

    /// Human explanation for the IMAP extension PostIMAP is using to detect changes on this
    /// account — the raw value is protocol jargon on its own. A port of the web's
    /// `syncTierDescription`.
    public static func syncTierDescription(_ tier: String?) -> String {
        switch tier {
        case "qresync":
            return "QRESYNC: the server reports exactly what changed, no rescan needed."
        case "condstore":
            return "CONDSTORE: the server reports changed messages by modification time."
        case "full":
            return "No fast change-detection extension on this server — folders are rescanned in full."
        default:
            return "Not yet determined."
        }
    }
}
