import Foundation
import MailVerdictKit
import Observation

/// Where the app's connection lives.
///
/// One place builds the API client, so the request factory's guarantee — that base URL and
/// bearer header are owned in exactly one spot — cannot be lost by a second construction site.
///
/// Credentials are held here rather than read from the Keychain per request: a Keychain lookup on
/// every call is both slow and a second source of truth for what the app is currently signed in
/// as.
@Observable
@MainActor
final class AppEnvironment {

    private(set) var router: Router
    private(set) var connection: Connection?

    /// Set when the backend refused the stored token, so the shell can offer a way back that is
    /// distinct from first launch.
    private(set) var lastAuthFailure: String?

    var backendURL: String {
        didSet { defaults.set(backendURL, forKey: Self.backendURLKey) }
    }

    private let defaults: UserDefaults
    private let tokens: MVKeychainTokenStore

    /// Everything that only exists once the app has somewhere to talk to. Grows with the
    /// mail/account stores as they are built; for now it is the plumbing those will sit on.
    struct Connection {
        let requestFactory: MVRequestFactory
        let apiClient: MVApiClient
    }

    private static let backendURLKey = "backendURL"

    init(defaults: UserDefaults = .standard, tokens: MVKeychainTokenStore = MVKeychainTokenStore()) {
        self.defaults = defaults
        self.tokens = tokens
        self.backendURL = defaults.string(forKey: Self.backendURLKey) ?? ""
        self.router = Router(gate: .needsConfiguration)

        if tokens.read() != nil {
            connect()
        }
    }

    /// Store a token and bring the connection up. Returns false if the URL is unusable.
    @discardableResult
    func signIn(backendURL url: String, token: String) -> Bool {
        backendURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tokens.write(token) else { return false }
        return connect()
    }

    /// Called when a request comes back 401 or 403.
    ///
    /// The token is cleared as well as the gate moved: leaving a rejected credential in the
    /// Keychain means the next launch tries it again and lands back here, which reads as the app
    /// being broken rather than as needing a new token.
    func handleAuthenticationFailure(detail: String?) {
        tokens.write(nil)
        connection = nil
        lastAuthFailure = detail
        router.gate = .tokenRejected
    }

    func signOut() {
        tokens.write(nil)
        connection = nil
        lastAuthFailure = nil
        router = Router(gate: .needsConfiguration)
    }

    @discardableResult
    private func connect() -> Bool {
        guard
            let factory = try? MVRequestFactory(
                baseURL: backendURL,
                tokenProvider: { [tokens] in tokens.read() }
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
