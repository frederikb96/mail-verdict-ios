import Foundation

/// What the share sheet needs from the server.
public protocol ShareBackend: Sendable {
    func accountsToShareInto() async throws -> [AccountResponse]
    func addToOrders(_ file: ShareFile) async throws
    func saveDraft(_ request: OutboxCreateRequest, uploads: [MVOutboxAttachmentUpload]) async throws
}

extension MVApiClient: ShareBackend {
    public func accountsToShareInto() async throws -> [AccountResponse] {
        try await listAccounts()
    }

    public func addToOrders(_ file: ShareFile) async throws {
        _ = try await uploadOrderFile(data: file.data, filename: file.filename, contentType: file.contentType)
    }

    public func saveDraft(_ request: OutboxCreateRequest, uploads: [MVOutboxAttachmentUpload]) async throws {
        _ = try await createOutbox(request, attachments: uploads)
    }
}
