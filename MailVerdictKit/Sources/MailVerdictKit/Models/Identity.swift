import Foundation

// Mirrors mail_verdict/api/schemas.py's identity shapes.

public struct IdentityCreate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "IdentityCreate"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case accountId = "account_id", address, displayName = "display_name",
            isDefault = "is_default"
    }
    public typealias CodingKeys = ContractKeys

    public let accountId: UUID
    public let address: String
    public let displayName: String?
    @MVDefaulted<MVDefaultFalse> public var isDefault: Bool

    public init(accountId: UUID, address: String, displayName: String? = nil, isDefault: Bool = false) {
        self.accountId = accountId
        self.address = address
        self.displayName = displayName
        self.isDefault = isDefault
    }
}

public struct IdentityUpdate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "IdentityUpdate"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case address, displayName = "display_name", isDefault = "is_default"
    }
    public typealias CodingKeys = ContractKeys

    public let address: String?
    public let displayName: String?
    public let isDefault: Bool?

    public init(address: String? = nil, displayName: String? = nil, isDefault: Bool? = nil) {
        self.address = address
        self.displayName = displayName
        self.isDefault = isDefault
    }
}

public struct IdentityResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "IdentityResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case id, accountId = "account_id", address, displayName = "display_name",
            isDefault = "is_default", createdAt = "created_at"
    }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let accountId: UUID
    public let address: String
    public let displayName: String?
    public let isDefault: Bool
    public let createdAt: Date

    public init(
        id: UUID, accountId: UUID, address: String, displayName: String?, isDefault: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.accountId = accountId
        self.address = address
        self.displayName = displayName
        self.isDefault = isDefault
        self.createdAt = createdAt
    }
}
