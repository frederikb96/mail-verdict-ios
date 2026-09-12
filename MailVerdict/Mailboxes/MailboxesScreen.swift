import MailVerdictKit
import SwiftUI

/// The app's root screen — one tap away from everything (UX design §1's own rule), and never
/// edited by a feature block: each row below only pushes a `Route` or sets `presentedCompose`,
/// which `RootView` already resolves to that block's own screen.
///
/// A stub until S4 replaces this file with the real account/folder/unified-view list — but it is
/// this block's stub, in this block's own directory, so nothing else needs to touch it to add
/// the real content.
struct MailboxesScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var healthStatus: String = "checking…"

    var body: some View {
        List {
            Section {
                MailRowView(data: .fixture)
                    .accessibilityIdentifier("mailboxes-fixture-row")
            } header: {
                Text("Mailboxes")
            } footer: {
                Text("Accounts and folders arrive here once the Mailboxes block replaces this stub.")
            }

            Section("MailVerdict") {
                NavigationLink("Spam Review", value: Route.spamReview)
                NavigationLink("Accounts", value: Route.accounts)
                NavigationLink("Settings", value: Route.settings)
            }

            Section {
                Text(environment.backendURL).foregroundStyle(.secondary)
                Text(healthStatus).foregroundStyle(.secondary)
                Button("Sign out", role: .destructive) { environment.signOut() }
                    .accessibilityIdentifier("signout")
            }
        }
        .navigationTitle("Mailboxes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.navigationPath.append(.notifications)
                } label: {
                    Image(systemName: MVSymbols.bell)
                }
                .accessibilityIdentifier("mailboxes-bell")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    environment.navigationPath.append(.search(initialQuery: nil))
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("mailboxes-search")
                Spacer()
                Button {
                    environment.presentedCompose = ComposeIntent(kind: .new(accountId: nil))
                } label: {
                    Image(systemName: MVSymbols.compose)
                }
                .accessibilityIdentifier("mailboxes-compose")
            }
            .padding()
            .background(.bar)
        }
        .task {
            do {
                let health = try await connection.apiClient.getHealth()
                healthStatus = "\(health.status) — postimap: \(health.postimapContract), db: \(health.database)"
            } catch {
                healthStatus = (error as? MVError)?.userMessage ?? "\(error)"
            }
        }
        #if DEBUG
            .screenshotReadyRoot(environment: environment, connection: connection)
        #endif
    }
}

extension MVMailRowData {
    /// A stable, deterministic sample for the fixture sweep and this stub's own preview — never
    /// used once a real Mailboxes/list store supplies real rows.
    static let fixture = MVMailRowData.plain(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000f1a7") ?? UUID(),
        isUnread: true, senderName: "MailVerdict", dateText: "09:41", subject: "Welcome to MailVerdict",
        isAnswered: false, hasAttachments: false, verdictIsSpam: false, isStarred: false,
        snippet: "This fixture row proves MailRowView renders before any real data exists.",
        avatarIdentity: "mailverdict@example.com"
    )
}
