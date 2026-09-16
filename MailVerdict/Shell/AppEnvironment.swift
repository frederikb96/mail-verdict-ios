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

    /// Device-local, applied to the whole window (Settings > Appearance) — `nil` means "follow
    /// the system", which is also the default before anyone has ever changed it.
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

        /// Which unified views contain a given folder — one instance for the whole app, updated
        /// by `MailboxesStore` on every load, so `placeResolver` below always resolves "was the
        /// last view unified" against the same membership data Mailboxes itself is showing,
        /// whichever screen asks.
        let membership: MailboxesUnifiedMembership

        /// The one place a message id becomes a path — a notification tap, a push tap and
        /// "Show in Folder" all resolve through this instance rather than each building its own,
        /// so the three can never land a message in different places for the same input.
        let placeResolver: MVMessagePlaceResolver

        /// Accounts, views, folders and photo indexes shared by every list and reader.
        let referenceCache: MVReferenceCache

        /// Conversations fetched ahead of the reader — on touch-down and for the rows on screen.
        let threadCache: MVThreadCache

        /// Every mail action on its way to the server — what the lists and the reader show on top
        /// of what they read.
        let intentLedger: MVIntentLedger
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
        connection?.intentLedger.stop()
        credentials.write(nil)
        connection = nil
        lastAuthFailure = detail
        router.gate = .tokenRejected
    }

    func signOut() {
        connection?.liveEventHub.disconnect()
        connection?.intentLedger.stop()
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

    /// The live stream closes in the background and reconnects the moment the app is back. Left
    /// open, it would die unobserved while the retry backoff grows toward its cap, and the list
    /// would read "Connecting…" for up to that long after returning.
    func handleScenePhaseChange(to phase: ScenePhase) {
        switch phase {
        case .background: connection?.liveEventHub.pause()
        case .active:
            connection?.liveEventHub.resume()
            connection?.intentLedger.resume()
        default: break
        }
    }

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

        let membership = MailboxesUnifiedMembership()
        let referenceCache = MVReferenceCache(backend: client)
        let threadCache = MVThreadCache(fetch: { try await client.getThread(messageId: $0) })
        // Held weakly by the hub; the connection owns both for as long as it exists.
        liveEventHub.subscribe(referenceCache)
        liveEventHub.subscribe(threadCache)
        connection?.intentLedger.stop()
        let intentLedger = MVIntentLedger(
            transport: client, persistence: Self.intentPersistence(serverURL: backendURL),
            connectivity: MVNetworkPathConnectivity(), toasts: toasts)
        connection = Connection(
            requestFactory: factory, apiClient: client, liveEventHub: liveEventHub,
            imageLoader: MVAuthenticatedImageLoader(apiClient: client), membership: membership,
            placeResolver: MVMessagePlaceResolver(apiClient: client, membershipLookup: membership),
            referenceCache: referenceCache, threadCache: threadCache, intentLedger: intentLedger)
        lastAuthFailure = nil
        router.gate = .ready
        return true
    }

    /// Application Support, so outstanding actions survive a relaunch; a fixture run keeps them in
    /// memory, so one screenshot's actions never replay into the next.
    private static func intentPersistence(serverURL: String) -> any MVIntentPersistence {
        #if DEBUG
            if MVFixtureLaunch.isEnabled() { return MVMemoryIntentPersistence() }
        #endif
        let directory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return MVFileIntentPersistence(directory: directory, serverURL: serverURL)
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
