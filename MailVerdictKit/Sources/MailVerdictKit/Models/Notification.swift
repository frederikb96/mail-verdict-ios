import Foundation

// Mirrors mail_verdict/api/schemas.py's PostIMAP-notification shapes — see that file's own
// docstring on NotificationResponse for how this differs from AlertResponse (Models/Alert.swift).

public struct NotificationResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "NotificationResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, accountId = "account_id", action, messageId = "message_id",
            folderId = "folder_id", outboxId = "outbox_id", error, detail,
            acknowledgedAt = "acknowledged_at", revertedAt = "reverted_at", createdAt = "created_at"
    }
    public typealias CodingKeys = ContractKeys

    public let id: Int
    public let accountId: UUID
    public let action: String
    public let messageId: UUID?
    public let folderId: UUID?
    public let outboxId: UUID?
    public let error: String?
    public let detail: [String: MVAnyJSON]?
    public let acknowledgedAt: Date?
    public let revertedAt: Date?
    public let createdAt: Date

    public init(
        id: Int, accountId: UUID, action: String, messageId: UUID?, folderId: UUID?,
        outboxId: UUID?, error: String?, detail: [String: MVAnyJSON]?, acknowledgedAt: Date?,
        revertedAt: Date?, createdAt: Date
    ) {
        self.id = id
        self.accountId = accountId
        self.action = action
        self.messageId = messageId
        self.folderId = folderId
        self.outboxId = outboxId
        self.error = error
        self.detail = detail
        self.acknowledgedAt = acknowledgedAt
        self.revertedAt = revertedAt
        self.createdAt = createdAt
    }
}

public struct NotificationCountResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "NotificationCountResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case unacknowledged }
    public typealias CodingKeys = ContractKeys

    public let unacknowledged: Int

    public init(unacknowledged: Int) {
        self.unacknowledged = unacknowledged
    }
}
