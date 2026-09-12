import Foundation
import MailVerdictKit
import Observation

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

    private let defaults: UserDefaults
    private let credentials: MVKeychainCredentialStore

    /// Everything that only exists once the app has somewhere to talk to. Grows with the
    /// mail/account stores as they are built; for now it is the plumbing those will sit on.
    struct Connection {
        let requestFactory: MVRequestFactory
        let apiClient: MVApiClient
    }

    private static let backendURLKey = "backendURL"

    init(
        defaults: UserDefaults = .standard,
        credentials: MVKeychainCredentialStore = MVKeychainCredentialStore()
    ) {
        self.defaults = defaults
        self.credentials = credentials
        self.backendURL = defaults.string(forKey: Self.backendURLKey) ?? ""
        self.router = Router(gate: .needsConfiguration)

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
        credentials.write(nil)
        connection = nil
        lastAuthFailure = detail
        router.gate = .tokenRejected
    }

    func signOut() {
        credentials.write(nil)
        connection = nil
        lastAuthFailure = nil
        router = Router(gate: .needsConfiguration)
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

        connection = Connection(requestFactory: factory, apiClient: client)
        lastAuthFailure = nil
        router.gate = .ready
        return true
    }
}
