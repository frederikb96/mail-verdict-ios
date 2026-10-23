import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What a reader page asks for beyond its document — inline images (`mv-attachment://`) and
/// sender photos (`mv-photo://`) — fetched with the app's credential, which a web view cannot
/// attach to a subresource itself. Each one served is kept in the offline cache, and served from
/// there when the server cannot be reached, so a saved conversation shows the images it showed.
public struct MVReaderResourceLoader: Sendable {
    private let api: MVApiClient
    private let offlineCache: MVOfflineCache?

    public init(api: MVApiClient, offlineCache: MVOfflineCache?) {
        self.api = api
        self.offlineCache = offlineCache
    }

    public func load(_ url: URL) async -> Result<MVOfflineResource, Error> {
        guard let (key, fetch) = request(for: url) else { return .failure(URLError(.unsupportedURL)) }
        do {
            let (data, contentType) = try await fetch()
            let resource = MVOfflineResource(data: data, mimeType: Self.mimeType(contentType))
            if let offlineCache {
                Task { await offlineCache.saveResource(resource.data, mimeType: resource.mimeType, key: key) }
            }
            return .success(resource)
        } catch {
            if error.mvIsServerUnreachable, let saved = await offlineCache?.resource(key: key) {
                return .success(saved)
            }
            return .failure(error)
        }
    }

    private func request(for url: URL) -> (String, @Sendable () async throws -> (Data, String?))? {
        let api = api
        if url.scheme?.lowercased() == MessageBodyRenderer.attachmentScheme,
            let messageId = url.host.flatMap(UUID.init(uuidString:)),
            let attachmentId = UUID(uuidString: url.lastPathComponent)
        {
            let key = "attachment-\(messageId.uuidString.lowercased())-\(attachmentId.uuidString.lowercased())"
            return (
                key,
                {
                    let result = try await api.getAttachment(messageId: messageId, attachmentId: attachmentId)
                    return (result.data, result.contentType)
                }
            )
        }
        if let contactId = ReaderPhotoURL.contactId(from: url) {
            return (
                "photo-\(contactId.uuidString.lowercased())",
                {
                    let result = try await api.getContactPhoto(contactId: contactId)
                    return (result.data, result.contentType)
                }
            )
        }
        return nil
    }

    static func mimeType(_ contentType: String?) -> String {
        contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
            ?? "application/octet-stream"
    }
}
