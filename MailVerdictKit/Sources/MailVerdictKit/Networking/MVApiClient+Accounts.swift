import Foundation

extension MVApiClient {

    public func listAccounts() async throws -> [AccountResponse] {
        try await send(path: "/api/accounts")
    }

    public func createAccount(_ request: AccountCreateRequest) async throws -> AccountResponse {
        try await send(path: "/api/accounts", method: "POST", body: try Self.encodeBody(request))
    }

    public func getAccount(id: UUID) async throws -> AccountResponse {
        try await send(path: "/api/accounts/\(id)")
    }

    public func updateAccount(id: UUID, _ request: AccountUpdateRequest) async throws -> AccountResponse {
        try await send(path: "/api/accounts/\(id)", method: "PATCH", body: try Self.encodeBody(request))
    }

    public func deleteAccount(id: UUID) async throws {
        try await sendNoContent(path: "/api/accounts/\(id)", method: "DELETE")
    }

    public func listFolders(accountId: UUID, timeout: TimeInterval? = nil) async throws -> [FolderResponse] {
        try await send(path: "/api/accounts/\(accountId)/folders", timeout: timeout)
    }

    public func getSyncStatus(accountId: UUID) async throws -> SyncStatusResponse {
        try await send(path: "/api/accounts/\(accountId)/sync-status")
    }

    public func triggerSync(accountId: UUID) async throws {
        try await sendNoContent(path: "/api/accounts/\(accountId)/sync", method: "POST")
    }

    public func setAccountEmoji(accountId: UUID, emoji: String?) async throws {
        try await sendNoContent(
            path: "/api/accounts/\(accountId)/emoji", method: "PUT",
            body: try Self.encodeBody(EmojiUpdate(emoji: emoji))
        )
    }
}
