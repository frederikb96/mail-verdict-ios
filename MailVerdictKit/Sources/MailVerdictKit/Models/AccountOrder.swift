import Foundation

// Mirrors mail_verdict/api/schemas.py's account display order shapes.

public struct AccountOrderResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "AccountOrderResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable { case order }
    public typealias CodingKeys = ContractKeys

    public let order: [UUID]

    public init(order: [UUID]) {
        self.order = order
    }
}

public struct AccountOrderUpdate: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "AccountOrderUpdate"
    public enum ContractKeys: String, CodingKey, CaseIterable { case order }
    public typealias CodingKeys = ContractKeys

    public let order: [UUID]

    public init(order: [UUID]) {
        self.order = order
    }
}
