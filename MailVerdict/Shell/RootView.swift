import MailVerdictKit
import SwiftUI

/// The app's outermost screen: the gate, and — once connected — a placeholder for whatever the
/// first real screen turns out to be.
struct RootView: View {
    @State private var environment = AppEnvironment()

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch environment.router.gate {
        case .needsConfiguration:
            SignInView(environment: environment, reason: .firstLaunch)
        case .tokenRejected:
            SignInView(environment: environment, reason: .rejected(environment.lastAuthFailure))
        case .ready:
            if let connection = environment.connection {
                ConnectedPlaceholderView(environment: environment, connection: connection)
            } else {
                // `ready` without a connection should be unreachable; showing sign-in is the only
                // state a user can act on, and a blank screen is the alternative.
                SignInView(environment: environment, reason: .firstLaunch)
            }
        }
    }
}

/// Stands in for whatever the first real screen turns out to be — deliberately undesigned, since
/// that is a separate decision from what makes the connection itself work. It exists only to
/// prove the connection is real: it calls the one route the app has (`GET /api/health`), so a
/// saved token that points at a backend which never answers is visible rather than assumed
/// working.
private struct ConnectedPlaceholderView: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var status: String = "checking…"

    var body: some View {
        VStack(spacing: 12) {
            Text(environment.backendURL)
            Text(status)
            Button("Sign out", role: .destructive) { environment.signOut() }
                .accessibilityIdentifier("signout")
        }
        .padding()
        .task {
            do {
                let health = try await connection.apiClient.getHealth()
                status = "\(health.status) — postimap: \(health.postimapContract), db: \(health.database)"
            } catch {
                status = (error as? MVError)?.userMessage ?? "\(error)"
            }
        }
    }
}
