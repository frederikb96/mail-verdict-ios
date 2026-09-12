import MailVerdictKit
import SwiftUI

@main
struct MailVerdictApp: App {

    /// The APNs token and silent pushes reach an app delegate or nothing; see `PushAppDelegate`.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate

    #if DEBUG
        /// Held for the app's lifetime; a listener that goes out of scope stops listening.
        private static let debugBridge = DebugBridge(router: DebugRoutes.make())
    #endif

    init() {
        #if DEBUG
            FixtureBootstrap.installIfRequested()
            Self.debugBridge.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

#if DEBUG

    /// The app's debug endpoints.
    ///
    /// Reachable from the build host because a simulator shares its network stack:
    /// `curl 127.0.0.1:8765/health`.
    enum DebugRoutes {

        /// Each feature block's own state routes (`/mailboxes/state`, `/list/state`,
        /// `/reader/state`, `/composer/state`, `/search/state`, …) get one entry here — naming a
        /// static registrar function the feature defines in its own directory
        /// (`MailVerdict/MailList/MailListDebugRoutes.swift`, and so on), never the route logic
        /// itself inline in this shared file. This is the one line a feature block adds to
        /// `MailVerdictApp.swift`; `make()` below needs no other change to pick it up.
        private static let featureRegistrars: [@Sendable (inout DebugRouter) -> Void] = [
            PushDebugRoutes.register,
            MailListDebugRoutes.register,
        ]

        static func make() -> DebugRouter {
            var router = DebugRouter()

            router.register("GET", "/health") { _ in
                .encoding([
                    "status": "ok",
                    "bundle": Bundle.main.bundleIdentifier ?? "?",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                    "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
                ])
            }

            router.register("GET", "/routes") { _ in
                .encoding(["routes": routeNames])
            }

            router.register("GET", "/logs") { request in
                let level = request.query["level"].flatMap(DebugLogBuffer.Level.init(rawValue:)) ?? .debug
                let limit = request.query["limit"].flatMap(Int.init) ?? 100
                return .encoding(DebugLogBuffer.shared.snapshot(minimumLevel: level, limit: limit))
            }

            // Every registered screenshot id, and the id the screen actually on top reported —
            // see ScreenshotRegistry.swift. `/screen/current` answers `{"id": null}` until some
            // screen calls `ScreenshotReporter.shared.report`, which only the destination screen
            // itself does once it has truly appeared, never the launcher that navigated to it.
            router.register("GET", "/screens") { _ in
                .encoding(["screens": ScreenshotRegistry.all.map(\.id)])
            }

            router.register("GET", "/screen/current") { _ in
                .encoding(["id": ScreenshotReporter.shared.currentId])
            }

            for registrar in featureRegistrars { registrar(&router) }

            routeNames = router.registeredRoutes
            return router
        }

        // Captured into a separate static rather than read off `router` inside the `/routes`
        // handler itself: that closure is built and stored mid-registration, before `/routes` (or
        // anything registered after it) exists, so reading `router.registeredRoutes` from inside
        // it would answer with whatever was registered up to that point — not the full list.
        private nonisolated(unsafe) static var routeNames: [String] = []
    }

#endif
