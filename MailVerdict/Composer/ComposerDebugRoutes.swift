#if DEBUG

    import Foundation
    import MailVerdictKit

    /// `/composer/state`: the open composer's dirty flag, recipients and attachment counts, plus
    /// how many sends are waiting in the undo window — read from the same stores the screen uses.
    enum ComposerDebugRoutes {

        struct Snapshot: Encodable {
            let open: Bool
            let composer: ComposerStore.DebugState?
            let pendingSends: Int
        }

        static func register(_ router: inout DebugRouter) {
            router.register("GET", "/composer/state") { _ in
                // The listener runs on its own queue; the stores are main-actor state.
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        let services = ComposerServices.shared
                        let composer = services.activeComposer
                        return .encoding(
                            Snapshot(
                                open: composer != nil, composer: composer?.debugState,
                                pendingSends: services.undoSend?.pending.count ?? 0))
                    }
                }
            }
        }
    }

#endif
