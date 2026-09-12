import Foundation

// Mirrors mail_verdict/api/schemas.py's remote-image-exception shapes.

public enum MVImageExceptionType: String, Sendable, Equatable, CaseIterable, Codable {
    case sender
    case domain
}

public struct ImageExceptionCreate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "ImageExceptionCreate"
    public enum ContractKeys: String, CodingKey, CaseIterable { case type, value }
    public typealias CodingKeys = ContractKeys

    public let type: MVImageExceptionType
    public let value: String

    public init(type: MVImageExceptionType, value: String) {
        self.type = type
        self.value = value
    }
}

public struct ImageExceptionResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "ImageExceptionResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case id, type, value, createdAt = "created_at" }
    public typealias CodingKeys = ContractKeys

    public let id: UUID
    public let type: String
    public let value: String
    public let createdAt: Date

    public init(id: UUID, type: String, value: String, createdAt: Date) {
        self.id = id
        self.type = type
        self.value = value
        self.createdAt = createdAt
    }
}
