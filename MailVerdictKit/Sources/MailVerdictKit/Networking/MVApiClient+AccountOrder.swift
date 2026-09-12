import Foundation

extension MVApiClient {

    public func getAccountOrder() async throws -> AccountOrderResponse {
        try await send(path: "/api/account-order")
    }

    public func setAccountOrder(order: [UUID]) async throws -> AccountOrderResponse {
        try await send(
            path: "/api/account-order", method: "PUT",
            body: try Self.encodeBody(AccountOrderUpdate(order: order))
        )
    }
}
