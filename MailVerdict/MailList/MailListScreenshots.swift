#if DEBUG

    import Foundation
    import MailVerdictKit
    import Observation

    /// The mail list's screenshot states, all over the fixture folder: the list itself, select
    /// mode with rows ticked, and the Options sheet a short left swipe opens. UIKit offers no way
    /// to open a row's swipe actions without a real gesture, so the swipe's own revealed buttons
    /// are a device check rather than a sweep entry.
    enum MailListScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(id: "list", destination: .route(route)) { _, _ in
                _ = await loadedStore()
            },
            MVScreenshotEntry(id: "list-select-mode", destination: .route(route)) { _, _ in
                guard let store = await loadedStore() else { return }
                store.setSelecting(true)
                for row in store.rows.prefix(3) { store.toggleSelection(of: row.id) }
                _ = await waitFor {
                    let state = MailListDebugState.shared.current
                    return state?.isSelecting == true && (state?.selectionCount ?? 0) == 3
                }
            },
            MVScreenshotEntry(id: "list-swipe-options", destination: .route(route)) { _, _ in
                guard let store = await loadedStore(), let row = store.rows.first else { return }
                MailListScreenshotStage.shared.optionsRowId = row.id
                _ = await waitFor { MailListScreenshotStage.shared.isOptionsSheetVisible }
            },
        ]

        private static let route = Route.list(MVMailListFixtures.scope, aroundMessageId: nil)

        /// The fixture list's store once its rows are on screen — the controller has applied
        /// them, not merely the store loaded them.
        @MainActor
        private static func loadedStore() async -> MVMailListStore? {
            let applied = await waitFor {
                MVMailListRegistry.shared.store(for: MVMailListFixtures.scope)?.phase == .loaded
                    && (MailListDebugState.shared.current?.loadedCount ?? 0) > 0
            }
            return applied ? MVMailListRegistry.shared.store(for: MVMailListFixtures.scope) : nil
        }

        @MainActor
        private static func waitFor(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<100 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }
    }

    /// Screenshot states that are not a `Route`: which row's Options sheet to open, and whether
    /// it has appeared.
    @Observable
    @MainActor
    final class MailListScreenshotStage {
        static let shared = MailListScreenshotStage()

        var optionsRowId: UUID?
        var isOptionsSheetVisible = false
    }

#endif
