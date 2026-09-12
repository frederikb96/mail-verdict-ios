import MailVerdictKit
import SwiftUI

#if DEBUG

    /// One screen the Mac workflow can drive the app into and capture — a stable id (matches
    /// `-MVFixtureScreen <id>` and what `GET /screen/current` reports), a destination to
    /// navigate to, and an optional async step run after arriving (ticking a row into select
    /// mode, opening a sheet over it, …) for a state that is not itself a `Route`/`ComposeIntent`.
    struct MVScreenshotEntry: Sendable {
        enum Destination: Sendable, Equatable {
            /// Mailboxes — the root, already on screen with no navigation needed.
            case root
            case route(Route)
            case compose(ComposeIntent)
        }

        let id: String
        let destination: Destination
        let prepare: (@MainActor @Sendable (AppEnvironment, AppEnvironment.Connection) async -> Void)?

        init(
            id: String, destination: Destination,
            prepare: (@MainActor @Sendable (AppEnvironment, AppEnvironment.Connection) async -> Void)? = nil
        ) {
            self.id = id
            self.destination = destination
            self.prepare = prepare
        }

        var isRoot: Bool {
            destination == .root
        }

        func matchesRoute(_ route: Route) -> Bool {
            destination == .route(route)
        }

        func matchesCompose(_ intent: ComposeIntent) -> Bool {
            destination == .compose(intent)
        }
    }

    /// The one list every feature's own screenshot entries concatenate into — never edited by a
    /// feature block. A block adds entries to its own `<Feature>Screenshots.entries` (one stub
    /// file per feature directory, exactly like the route stubs) and this file needs no change to
    /// pick them up.
    enum ScreenshotRegistry {
        static let all: [MVScreenshotEntry] =
            MailboxesScreenshots.entries
            + MailListScreenshots.entries
            + ReaderScreenshots.entries
            + ComposerScreenshots.entries
            + SearchScreenshots.entries
            + SpamReviewScreenshots.entries
            + NotificationsScreenshots.entries
            + SettingsScreenshots.entries
            + AccountsScreenshots.entries
            + PushScreenshots.entries

        static func entry(id: String) -> MVScreenshotEntry? {
            all.first { $0.id == id }
        }
    }

    /// What `GET /screen/current` reports — set by the screen itself once it has actually
    /// appeared (`View.screenshotReady*` below), never by whatever triggered the navigation. A
    /// sign-in gate or a crash never calls this, so the debug bridge can never be made to claim a
    /// screen it never reached.
    final class ScreenshotReporter: @unchecked Sendable {
        static let shared = ScreenshotReporter()

        private let lock = NSLock()
        private var _currentId: String?

        var currentId: String? {
            lock.lock()
            defer { lock.unlock() }
            return _currentId
        }

        func report(_ id: String) {
            lock.lock()
            defer { lock.unlock() }
            _currentId = id
        }
    }

    extension View {
        /// Applied by the root (Mailboxes) screen only — the one entry point with no `Route` of
        /// its own to match against.
        func screenshotReadyRoot(environment: AppEnvironment, connection: AppEnvironment.Connection) -> some View {
            task {
                guard MVFixtureLaunch.isEnabled(), let targetId = MVFixtureLaunch.targetScreenId(),
                    let entry = ScreenshotRegistry.entry(id: targetId), entry.isRoot
                else { return }
                await entry.prepare?(environment, connection)
                ScreenshotReporter.shared.report(entry.id)
            }
        }

        /// Applied by a route-reached screen to its own body, passing the exact `Route` it was
        /// constructed with — `RootView`'s `navigationDestination` switch already has this value
        /// for every case, so there is nothing to re-derive.
        func screenshotReady(
            route: Route, environment: AppEnvironment, connection: AppEnvironment.Connection
        ) -> some View {
            task {
                guard MVFixtureLaunch.isEnabled(), let targetId = MVFixtureLaunch.targetScreenId(),
                    let entry = ScreenshotRegistry.entry(id: targetId), entry.matchesRoute(route)
                else { return }
                await entry.prepare?(environment, connection)
                ScreenshotReporter.shared.report(entry.id)
            }
        }

        /// Applied by `ComposerScreen` to its own body, passing the `ComposeIntent` it was
        /// presented with.
        func screenshotReady(
            compose intent: ComposeIntent, environment: AppEnvironment, connection: AppEnvironment.Connection
        ) -> some View {
            task {
                guard MVFixtureLaunch.isEnabled(), let targetId = MVFixtureLaunch.targetScreenId(),
                    let entry = ScreenshotRegistry.entry(id: targetId), entry.matchesCompose(intent)
                else { return }
                await entry.prepare?(environment, connection)
                ScreenshotReporter.shared.report(entry.id)
            }
        }
    }

#endif
