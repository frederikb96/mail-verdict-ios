import Foundation
import MailVerdictKit

#if DEBUG

    /// Fixture data for the Spam Review screen's own screenshot sweep.
    enum SpamReviewFixtures {
        /// The screen's own store, set from its `.task` — `MVScreenshotEntry.prepare` has no
        /// reach into a screen's `@State`, so this is how it finds the instance to reload once
        /// fixture routes exist. Weak: a screen that goes away must not keep its store alive.
        @MainActor static weak var activeStore: SpamReviewStore?

        static func registerIfNeeded() {
            guard MVFixtureLaunch.isEnabled() else { return }
            MailboxesFixtures.registerIfNeeded()
            // Encoded eagerly, outside the closure: `SpamReviewListResponse` is not `Sendable`,
            // and the fixture body closure is `@Sendable` — caught only on a Mac compile.
            let data = (try? JSONEncoder.mvDefault.encode(response)) ?? Data("{}".utf8)
            MVFixtureURLProtocol.register(method: "GET", path: "/api/verdicts/spam-review") { data }
        }

        private static var response: SpamReviewListResponse {
            SpamReviewListResponse(
                items: [
                    SpamReviewItem(
                        messageId: UUID(uuidString: "00000000-0000-0000-0000-0000000061a1")!,
                        accountId: MailboxesFixtures.accountId, folderId: MailboxesFixtures.inboxId, isJunk: true,
                        subject: "You have won a prize!", fromAddr: "noreply@totally-legit.example",
                        receivedAt: Date(timeIntervalSinceNow: -1800), snippet: "Click here to claim",
                        verdictId: UUID(), modelUsed: "gpt-4o-mini",
                        reasoning: "Generic prize-claim language, no prior relationship with sender.",
                        verdictCreatedAt: Date(timeIntervalSinceNow: -1800)
                    )
                ],
                hasMore: false, nextCursor: nil
            )
        }
    }

#endif
