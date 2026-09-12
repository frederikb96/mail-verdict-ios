import Foundation
import Observation

/// One account's detail screen: status, sync toggle, the read-only server details, emoji, and the
/// destructive actions (sync now, edit, delete). The three sub-screens (folder order, image
/// exceptions, identities) are each their own store.
@Observable
@MainActor
public final class MVAccountDetailStore {
    /// `.loaded` carries the account it loaded — there is no state in which the screen is
    /// "loaded" and has nothing to show.
    public enum LoadState {
        case loading
        case loaded(AccountResponse)
        case failed(Error)

        public var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    public let accountId: UUID
    public private(set) var syncStatus: SyncStatusResponse?
    public private(set) var state: LoadState = .loading
    /// Set when a live `accountsChanged` refresh finds this account gone — the account was
    /// deleted from elsewhere while this screen stayed open. The screen shows a message and
    /// pops rather than re-rendering a 404 as a retry loop.
    public private(set) var wasDeletedElsewhere = false

    private let apiClient: MVApiClient
    private var liveSubscriptionToken: MVSubscriptionToken?

    public init(accountId: UUID, apiClient: MVApiClient) {
        self.accountId = accountId
        self.apiClient = apiClient
    }

    public var account: AccountResponse? {
        if case .loaded(let account) = state { return account }
        return nil
    }

    public var connectionState: MVAccountConnectionState {
        guard let account else { return .ok }
        return .classify(state: account.state, lastFullSync: syncStatus?.lastFullSync != nil)
    }

    // MARK: - Live updates

    public func subscribeToLive(_ hub: LiveEventHub) {
        guard liveSubscriptionToken == nil else { return }
        liveSubscriptionToken = hub.subscribe(self)
    }

    public func unsubscribeFromLive(_ hub: LiveEventHub) {
        guard let token = liveSubscriptionToken else { return }
        hub.unsubscribe(token)
        liveSubscriptionToken = nil
    }

    public func load() async {
        state = .loading
        do {
            let fetched = try await apiClient.getAccount(id: accountId)
            syncStatus = try? await apiClient.getSyncStatus(accountId: accountId)
            state = .loaded(fetched)
        } catch {
            state = .failed(error)
        }
    }

    /// A background refresh triggered by `accountsChanged`, not the screen's own load — a
    /// transient failure here leaves the last good state on screen rather than replacing it
    /// with an error view; only a 404 (the account is actually gone) is acted on.
    private func refreshAfterLiveChange() async {
        do {
            let fetched = try await apiClient.getAccount(id: accountId)
            syncStatus = try? await apiClient.getSyncStatus(accountId: accountId)
            state = .loaded(fetched)
        } catch {
            if Self.isNotFound(error) {
                wasDeletedElsewhere = true
            }
        }
    }

    public func setActive(_ isActive: Bool) async throws {
        guard let previous = account else { return }
        state = .loaded(
            AccountResponse(
                id: previous.id, name: previous.name, imapHost: previous.imapHost,
                imapPort: previous.imapPort, imapUser: previous.imapUser, smtpHost: previous.smtpHost,
                smtpPort: previous.smtpPort, smtpUser: previous.smtpUser, isActive: isActive,
                state: previous.state, stateError: previous.stateError,
                capabilities: previous.capabilities, createdAt: previous.createdAt,
                updatedAt: previous.updatedAt, emoji: previous.emoji, spamEnabled: previous.spamEnabled,
                folderOrder: previous.folderOrder, trashRetentionDays: previous.trashRetentionDays,
                junkRetentionDays: previous.junkRetentionDays
            ))
        do {
            _ = try await apiClient.updateAccount(id: accountId, AccountUpdateRequest(isActive: isActive))
        } catch {
            state = .loaded(previous)
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
        state = .loaded(try await apiClient.updateAccount(id: accountId, request))
    }

    public func delete() async throws {
        try await apiClient.deleteAccount(id: accountId)
    }

    private static func isNotFound(_ error: Error) -> Bool {
        switch error as? MVError {
        case .detail(_, let status)?, .http(let status, _)?: return status == 404
        default: return false
        }
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

    /// The short label `syncTierDescription`'s sentence expands on — words, not the raw
    /// protocol-extension name the server sends ("qresync").
    public static func syncTierLabel(_ tier: String?) -> String {
        switch tier {
        case "qresync": return "QRESYNC"
        case "condstore": return "CONDSTORE"
        case "full": return "Full rescan"
        default: return "Pending"
        }
    }
}

extension MVAccountDetailStore: LiveEventSubscriber {
    public func apply(_ invalidations: [MVLiveInvalidation]) {
        guard invalidations.contains(.accountsChanged) else { return }
        Task { await self.refreshAfterLiveChange() }
    }
}
