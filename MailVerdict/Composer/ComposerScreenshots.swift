import MailVerdictKit
import SwiftUI

#if DEBUG

    /// The composer's screenshot entries: an empty new message, and a reply showing its quote card.
    ///
    /// The fixture routes are registered on arrival rather than up front — every feature's list
    /// is built at launch, so routes registered then would answer other screens' requests too.
    /// The composer may already have tried to load by then, so it loads again, and the capture
    /// waits for it to finish rather than catching its spinner.
    enum ComposerScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(
                id: "composer-empty",
                destination: .compose(
                    ComposeIntent(
                        id: UUID(uuidString: "C0000000-0000-4000-8000-0000000000A1")!, kind: .new(accountId: nil))),
                prepare: { _, _ in await loadFixtures() }),
            MVScreenshotEntry(
                id: "composer-reply",
                destination: .compose(
                    ComposeIntent(
                        id: UUID(uuidString: "C0000000-0000-4000-8000-0000000000A2")!,
                        kind: .reply(messageId: ComposeFixtures.messageId))),
                prepare: { _, _ in await loadFixtures() }),
        ]

        @MainActor
        private static func loadFixtures() async {
            ComposeFixtures.register()
            guard let store = await poll({ ComposerServices.shared.activeComposer }) else { return }
            _ = await poll { store.phase == .loading ? nil : true }
            if store.phase != .editing { await store.load() }
        }

        /// Up to five seconds, checked every 50 ms.
        @MainActor
        private static func poll<Value>(_ probe: @MainActor () -> Value?) async -> Value? {
            for _ in 0..<100 {
                if let value = probe() { return value }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
    }

#endif
