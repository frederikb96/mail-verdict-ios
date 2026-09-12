import MailVerdictKit
import SwiftUI
import UIKit

/// Fetches and caches an avatar image in memory. `AsyncImage` has no way to attach this backend's
/// own bearer/basic credential, so an embedded contact photo behind auth would never load through
/// it — this loader goes through `MVApiClient` instead for that case, and fetches a `.remote`
/// source (a third party's own address, already checked against the requesting account's
/// image-allowlist by the photo-index request itself) directly, deliberately never attaching this
/// backend's credential to someone else's server.
///
/// One instance per connection, held by `AppEnvironment.Connection` so every `AvatarView` shares
/// the same cache rather than each re-fetching the same sender's photo.
@MainActor
final class MVAuthenticatedImageLoader {
    private let apiClient: MVApiClient
    private var cache: [MVAvatarPhotoSource: Image] = [:]
    private var inFlight: [MVAvatarPhotoSource: Task<Image?, Never>] = [:]

    /// A `.remote` source never carries this backend's credential, but still goes through a
    /// session of its own rather than `URLSession.shared` — `MVFixtureURLProtocol` is only ever
    /// installed into a configuration explicitly, never picked up by a session it wasn't asked
    /// into, so fixture mode needs this one named the same way every other session is.
    private static let remoteSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        #if DEBUG
            MVFixtureURLProtocol.installIfEnabled(in: configuration)
        #endif
        return URLSession(configuration: configuration)
    }()

    init(apiClient: MVApiClient) {
        self.apiClient = apiClient
    }

    func image(for source: MVAvatarPhotoSource) async -> Image? {
        if let cached = cache[source] { return cached }
        if let running = inFlight[source] { return await running.value }

        let apiClient = apiClient
        let task = Task<Image?, Never> {
            let data: Data?
            switch source {
            case .embedded(let contactId):
                data = try? await apiClient.getContactPhoto(contactId: contactId).data
            case .remote(let url):
                data = try? await Self.remoteSession.data(from: url).0
            }
            guard let data, let uiImage = UIImage(data: data) else { return nil }
            return Image(uiImage: uiImage)
        }
        inFlight[source] = task

        let result = await task.value
        inFlight[source] = nil
        if let result { cache[source] = result }
        return result
    }
}

private struct MVImageLoaderKey: EnvironmentKey {
    static let defaultValue: MVAuthenticatedImageLoader? = nil
}

extension EnvironmentValues {
    /// `nil` outside a connected screen (fixture/screenshot mode, previews) — `AvatarView` falls
    /// back to initials rather than requiring every call site to thread a loader through.
    var mvImageLoader: MVAuthenticatedImageLoader? {
        get { self[MVImageLoaderKey.self] }
        set { self[MVImageLoaderKey.self] = newValue }
    }
}
