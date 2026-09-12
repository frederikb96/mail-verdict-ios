import Foundation
import MailVerdictKit
import Observation
import SwiftUI

/// Where the app's connection lives.
///
/// One place builds the API client, so the request factory's guarantee — that base URL and
/// credential are owned in exactly one spot — cannot be lost by a second construction site.
///
/// Credentials are held here rather than read from the Keychain per request: a Keychain lookup on
/// every call is both slow and a second source of truth for what the app is currently signed in
/// as.
@Observable
@MainActor
final class AppEnvironment {

    private(set) var router: Router
    private(set) var connection: Connection?

    /// Set when the backend refused the stored credential, so the shell can offer a way back that
    /// is distinct from first launch.
    private(set) var lastAuthFailure: String?

    var backendURL: String {
        didSet { defaults.set(backendURL, forKey: Self.backendURLKey) }
    }

    /// The `NavigationStack`'s own path — restored from `MVPersistedPath` at launch (already
    /// stripped of any trailing reader, so cold launch is never deeper than the list) and saved
    /// back on every change by whoever owns the stack (`RootView`).
    var navigationPath: [Route]

    /// The composer's one sheet-presentation slot — `nil` means no composer is showing. Every
    /// entry point (compose buttons, Reply/Reply All/Forward, a `mailto:` link, a collapsed
    /// draft, Undo Send, "New Message to…") sets this rather than pushing a `Route`, since a
    /// composer is a modal, not a navigation destination.
    var presentedCompose: ComposeIntent?

    let toasts = MVToastStore()

    /// Device-local, applied to the whole window (UX design's Settings > Appearance) — `nil`
    /// means "follow the system", which is also the default before anyone has ever changed it.
    var colorScheme: ColorScheme? {
        get { Self.colorScheme(from: defaults.string(forKey: Self.colorSchemeKey)) }
        set { defaults.set(Self.string(from: newValue), forKey: Self.colorSchemeKey) }
    }

    private let defaults: UserDefaults
    private let credentials: MVKeychainCredentialStore

    /// Everything that only exists once the app has somewhere to talk to. Grows with the
    /// mail/account stores as they are built; for now it is the plumbing those will sit on.
    struct Connection {
        let requestFactory: MVRequestFactory
        let apiClient: MVApiClient

        /// The one SSE connection for the whole app — every store subscribes to this instance
        /// rather than opening its own, since the backend's event ring has no notion of "this
        /// stream is for screen X".
        let liveEventHub: LiveEventHub

        /// Shared so every `AvatarView` reads from the same in-memory cache rather than each
        /// re-fetching the same sender's photo.
        let imageLoader: MVAuthenticatedImageLoader
    }

    /// Internal, not private — `FixtureBootstrap` seeds this default too, so a fixture-mode
    /// launch has a base URL to build `MVRequestFactory` from without restating the key.
    /// `nonisolated`: a plain immutable `String` carries no actor state, and `FixtureBootstrap`
    /// reads it from `MailVerdictApp.init()`, which runs before any actor context exists.
    nonisolated static let backendURLKey = "backendURL"
    private static let colorSchemeKey = "colorScheme"

    init(
        defaults: UserDefaults = .standard,
        credentials: MVKeychainCredentialStore = MVKeychainCredentialStore()
    ) {
        self.defaults = defaults
        self.credentials = credentials
        self.backendURL = defaults.string(forKey: Self.backendURLKey) ?? ""
        self.router = Router(gate: .needsConfiguration)
        self.navigationPath = MVPersistedPath.load(from: defaults)

        if credentials.read() != nil {
            connect()
        }
    }

    /// Store a credential and bring the connection up. Returns false if the URL is unusable.
    @discardableResult
    func signIn(backendURL url: String, mode: MVAuthMode) -> Bool {
        backendURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credentials.write(mode) else { return false }
        return connect()
    }

    /// Called when a request comes back 401 or 403 — the stored credential cannot be used as-is,
    /// and clearing it is what moves the gate rather than leaving the app looking broken on every
    /// subsequent call. A login-proxy redirect (`MVError.proxyRequiresBrowserLogin`) is a
    /// different failure — the credential may be fine, the proxy in front of it just cannot take
    /// one — so it surfaces to whichever screen made the call instead of wiping the Keychain.
    func handleAuthenticationFailure(detail: String?) {
        connection?.liveEventHub.disconnect()
        credentials.write(nil)
        connection = nil
        lastAuthFailure = detail
        router.gate = .tokenRejected
    }

    func signOut() {
        connection?.liveEventHub.disconnect()
        credentials.write(nil)
        connection = nil
        lastAuthFailure = nil
        router = Router(gate: .needsConfiguration)
    }

    /// Persists `navigationPath` — called from `RootView`'s own `.onChange`, not automatically
    /// on every mutation, so a rapid sequence of pushes during one navigation gesture writes once
    /// rather than once per frame.
    func persistNavigationPath() {
        MVPersistedPath.save(navigationPath, to: defaults)
    }

    /// `scenePhase` going `.active` is where a later block's own stores do their bounded re-read
    /// of every open list plus a counts refetch (UX design §2.0's "Foreground return" rule) —
    /// nothing to bind that to yet, since no store exists, but the call site belongs here rather
    /// than in `RootView` so a store added later has one place to subscribe from.
    func handleScenePhaseChange(to phase: ScenePhase) {}

    @discardableResult
    private func connect() -> Bool {
        guard
            let factory = try? MVRequestFactory(
                baseURL: backendURL,
                authProvider: { [credentials] in credentials.read() ?? .none }
            )
        else {
            return false
        }

        // Weak, and hopped to the main actor: the callback fires from whatever task made the
        // request, and a strong reference here would be a retain cycle through the client the
        // connection holds.
        let client = MVApiClient(requestFactory: factory) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleAuthenticationFailure(detail: error.userMessage)
            }
        }

        let liveEventHub = LiveEventHub(requestFactory: factory)
        liveEventHub.connect()

        connection = Connection(
            requestFactory: factory, apiClient: client, liveEventHub: liveEventHub,
            imageLoader: MVAuthenticatedImageLoader(apiClient: client))
        lastAuthFailure = nil
        router.gate = .ready
        return true
    }

    private static func colorScheme(from stored: String?) -> ColorScheme? {
        switch stored {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private static func string(from colorScheme: ColorScheme?) -> String? {
        switch colorScheme {
        case .light: return "light"
        case .dark: return "dark"
        default: return nil
        }
    }
}
