import Foundation
import MailVerdictKit

#if DEBUG

    /// Fixture data for the Search screen's own screenshot sweep — a couple of results with bold
    /// snippet markers, so the chip bar and a populated result list both render.
    enum SearchFixtures {
        /// The screen's own store, set from its `.task` — `MVScreenshotEntry.prepare` has no
        /// reach into a screen's `@State`, so this is how it finds the instance to reload once
        /// fixture routes exist. Weak: a screen that goes away must not keep its store alive.
        @MainActor static weak var activeStore: SearchStore?

        static func registerIfNeeded() {
            guard MVFixtureLaunch.isEnabled() else { return }

            register(.get, "/api/search", response)
            register(.get, "/api/search/date-bounds", dateBounds)
        }

        private static var response: SearchResponse {
            let accountId = MailboxesFixtures.accountId
            let folderId = MailboxesFixtures.inboxId
            return SearchResponse(
                results: [
                    SearchResult(
                        id: UUID(uuidString: "00000000-0000-0000-0000-0000000051a1")!, accountId: accountId,
                        folderId: folderId, threadId: UUID(), subject: "Invoice #4471",
                        fromAddr: "billing@example.com", toAddrs: .string("me@posteo.de"),
                        receivedAt: Date(timeIntervalSinceNow: -3600),
                        snippet: "Your **invoice** for last month is attached.",
                        mirroredAt: Date(timeIntervalSinceNow: -3600), hasAttachments: true, verdictIsSpam: false
                    ),
                    SearchResult(
                        id: UUID(uuidString: "00000000-0000-0000-0000-0000000051a2")!, accountId: accountId,
                        folderId: folderId, threadId: UUID(), subject: "Re: Invoice question",
                        fromAddr: "support@example.com", toAddrs: .string("me@posteo.de"),
                        receivedAt: Date(timeIntervalSinceNow: -7200),
                        snippet: "Thanks for your **invoice** question, here is the answer.",
                        mirroredAt: Date(timeIntervalSinceNow: -7200), hasAttachments: false, verdictIsSpam: false
                    ),
                ],
                hasMore: false, nextCursor: nil, query: "invoice", total: 2
            )
        }

        private static var dateBounds: SearchDateBoundsResponse {
            SearchDateBoundsResponse(
                oldest: Date(timeIntervalSinceNow: -86400 * 365), newest: Date()
            )
        }

        private enum Method: String { case get = "GET" }

        /// Encodes eagerly and captures the resulting `Data`, not `value` itself — `T: Encodable`
        /// says nothing about `Sendable`, and the fixture body closure is `@Sendable`. Caught only
        /// on a Mac compile; `Tooling/swift6-lint.py` has no rule for it yet.
        private static func register<T: Encodable>(_ method: Method, _ path: String, _ value: T) {
            let data = (try? JSONEncoder.mvDefault.encode(value)) ?? Data("{}".utf8)
            MVFixtureURLProtocol.register(method: method.rawValue, path: path) { data }
        }
    }

#endif
