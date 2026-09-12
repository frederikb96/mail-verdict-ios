import MailVerdictKit
import SwiftUI
import UIKit

/// Backend address and credential entry.
///
/// One screen serves two situations, because the fields are the same and only the explanation
/// differs. They are kept as distinct cases rather than one flag, so a rejected credential can say
/// what happened instead of pretending nothing has been set up yet.
struct SignInView: View {

    enum Reason {
        case firstLaunch
        /// The stored credential was refused; the detail is whatever the backend said, if anything.
        case rejected(String?)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case none = "None"
        case bearer = "Bearer token"
        case basic = "Basic auth"

        var id: String { rawValue }
    }

    let environment: AppEnvironment
    let reason: Reason

    @State private var url: String = ""
    @State private var mode: Mode = .bearer
    @State private var token: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var failed = false
    @State private var testResult: String?
    @State private var testing = false
    @FocusState private var tokenFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if case .rejected(let detail) = reason {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("The saved credential was refused.")
                                if let detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Backend") {
                    TextField("https://…", text: $url)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("signin-url")
                }

                Section("Authentication") {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .accessibilityIdentifier("signin-mode")

                    switch mode {
                    case .none:
                        Text("No credential is sent — a LAN, Tailscale or VPN install with no proxy.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    case .bearer:
                        // Nobody types an access token, so paste has to be the obvious path — but
                        // the field is still secure, because the value is a long-lived credential.
                        SecureField("Paste the access token", text: $token)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($tokenFocused)
                            .accessibilityIdentifier("signin-token")
                        Button("Paste from clipboard") {
                            if let pasted = UIPasteboard.general.string {
                                token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .accessibilityIdentifier("signin-paste")
                    case .basic:
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("signin-username")
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("signin-password")
                    }

                    if sendsCredentialOverCleartext {
                        Label {
                            Text(
                                "This address is http, not https — the \(mode == .bearer ? "token" : "username and password") will travel in the clear."
                            )
                            .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .accessibilityIdentifier("signin-cleartext-warning")
                    }
                }

                if failed {
                    Text("That backend address could not be used. It needs a scheme, http or https.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Section {
                    Button("Test Connection") { Task { await testConnection() } }
                        .disabled(url.isEmpty || testing)
                        .accessibilityIdentifier("signin-test")
                    if testing {
                        Text("Checking…").font(.footnote).foregroundStyle(.secondary)
                    } else if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Connect") { connect() }
                        .disabled(url.isEmpty || !isCredentialFilled)
                        .accessibilityIdentifier("signin-connect")
                }
            }
            .navigationTitle(title)
        }
        .onAppear {
            // Prefilled rather than blank: on a rejection the address is definitely right and
            // only the credential needs replacing. On first launch there is nothing to prefill.
            if url.isEmpty { url = environment.backendURL }
            if case .rejected = reason { tokenFocused = true }
        }
    }

    private var sendsCredentialOverCleartext: Bool {
        mode != .none && url.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
    }

    private var isCredentialFilled: Bool {
        switch mode {
        case .none: return true
        case .bearer: return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .basic: return !username.isEmpty && !password.isEmpty
        }
    }

    private var title: String {
        switch reason {
        case .firstLaunch: "Connect"
        case .rejected: "Sign in again"
        }
    }

    private func authMode() -> MVAuthMode {
        switch mode {
        case .none: return .none
        case .bearer: return .bearer(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        case .basic: return .basic(username: username, password: password)
        }
    }

    private func connect() {
        failed = !environment.signIn(backendURL: url, mode: authMode())
        if !failed {
            token = ""
            password = ""
        }
    }

    /// Tries the credential without saving it — a throwaway client, never the app's own
    /// connection, so a failed test leaves whatever was already signed in untouched.
    private func testConnection() async {
        testing = true
        testResult = nil
        defer { testing = false }

        let credential = authMode()
        guard
            let factory = try? MVRequestFactory(
                baseURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
                authProvider: { credential }
            )
        else {
            testResult = "That address could not be used."
            return
        }
        let client = MVApiClient(requestFactory: factory)
        do {
            let health = try await client.getHealth()
            let versionSuffix = health.version.map { " (server \($0))" } ?? ""
            testResult =
                health.isReady
                ? "Reachable and ready\(versionSuffix)."
                : "Reachable, but not ready yet\(versionSuffix)."
        } catch {
            testResult = error.mvUserMessage
        }
    }
}
