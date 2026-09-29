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
            MVScreenshotEntry(id: "list-move-picker", destination: .route(route)) { _, _ in
                guard let store = await loadedStore(), let row = store.rows.first else { return }
                MailListScreenshotStage.shared.movePickerRowId = row.id
                _ = await waitFor { MailListScreenshotStage.shared.isMovePickerVisible }
                // `MovePickerSheet` loads its own target list asynchronously from a fixture
                // response after it appears — `isMovePickerVisible` only means the sheet is on
                // screen, not that its list (the glacier row among the targets) has painted yet.
                try? await Task.sleep(for: .milliseconds(300))
            },
        ]

        private static let route = Route.list(MVMailListFixtures.scope, aroundMessageId: nil)

        /// The fixture list's store once its rows are on screen — the controller has applied
        /// them, not merely the store loaded them.
        @MainActor
        private static func loadedStore() async -> MVMailListStore? {
            let applied = await waitFor {
                MailListScreenshotStage.shared.store?.phase == .loaded
                    && (MailListDebugState.shared.current?.loadedCount ?? 0) > 0
            }
            return applied ? MailListScreenshotStage.shared.store : nil
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

        @ObservationIgnored weak var store: MVMailListStore?
        var optionsRowId: UUID?
        var isOptionsSheetVisible = false
        /// Which row's Move picker to open with no touch available, and whether it has appeared —
        /// the fixture folder order carries a glacier target, so this is what the sweep uses to
        /// show it.
        var movePickerRowId: UUID?
        var isMovePickerVisible = false
    }

#endif
