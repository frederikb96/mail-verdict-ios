import MailVerdictKit
import SwiftUI

/// The verdict queue — every message the classifier currently calls spam with no ruling yet,
/// thumbs, swipes and Accept/Reject All.
struct SpamReviewScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: SpamReviewStore
    @State private var accounts: [AccountResponse] = []
    @State private var pendingBulk: PendingBulk?
    @State private var isDeciding = false

    private enum PendingBulk: Identifiable {
        case accept
        case reject
        var id: Self { self }
    }

    init(environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.environment = environment
        self.connection = connection
        self._store = State(initialValue: SpamReviewStore(apiClient: connection.apiClient))
    }

    var body: some View {
        content
            .navigationTitle("Spam Review")
            .navigationSubtitle("\(store.items.count) to review")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Accept All") { pendingBulk = .accept }
                            .disabled(store.items.isEmpty || store.isBulkRunning)
                        Button("Reject All") { pendingBulk = .reject }
                            .disabled(store.items.isEmpty || store.isBulkRunning)
                    } label: {
                        Image(systemName: MVSymbols.options)
                    }
                }
            }
            .alert(item: $pendingBulk) { bulk in
                switch bulk {
                case .accept:
                    Alert(
                        title: Text("Confirm \(store.items.count) messages as spam?"),
                        message: Text(
                            "Records agreement with the classifier for every message currently listed. Nothing moves."),
                        primaryButton: .default(Text("Accept All")) { Task { await runBulk(agree: true) } },
                        secondaryButton: .cancel()
                    )
                case .reject:
                    Alert(
                        title: Text("Correct \(store.items.count) messages?"),
                        message: Text(
                            "Records a correction for every message currently listed, and moves any of them still sitting in Junk back to the inbox."
                        ),
                        primaryButton: .default(Text("Reject All")) { Task { await runBulk(agree: false) } },
                        secondaryButton: .cancel()
                    )
                }
            }
            .task {
                #if DEBUG
                    SpamReviewFixtures.activeStore = store
                #endif
                store.subscribeToLive(connection.liveEventHub)
                accounts = (try? await connection.apiClient.listAccounts()) ?? []
                await store.load()
            }
            .onDisappear { store.unsubscribeFromLive(connection.liveEventHub) }
            #if DEBUG
                .screenshotReady(route: .spamReview, environment: environment, connection: connection)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView()
        } else if let errorMessage = store.errorMessage {
            ErrorStateView(message: errorMessage) { Task { await store.load() } }
        } else if store.items.isEmpty {
            EmptyStateView(systemImage: MVSymbols.nothingToReview, message: "Nothing to review")
        } else {
            List {
                ForEach(store.items) { item in
                    row(for: item)
                }
                if store.hasOlder {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await store.loadOlder() }
                }
            }
        }
    }

    /// Not a `Button` wrapping the whole row: the two thumbs need their own independent tap
    /// targets, which a `Button` nested inside another `Button`'s label cannot reliably give —
    /// `onTapGesture` on the row's own content shape opens the reader instead, and a thumb's tap
    /// is consumed by its own `Button` before it ever reaches that gesture.
    private func row(for item: SpamReviewItem) -> some View {
        SpamReviewRow(
            item: item, accountChip: accounts.count > 1 ? accountName(for: item.accountId) : nil,
            onConfirmSpam: { Task { await decide(item, agree: true) } },
            onNotSpam: { Task { await decide(item, agree: false) } }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            environment.navigationPath.append(.reader(ReaderContext(source: .spamReview, messageId: item.messageId)))
        }
        .disabled(isDeciding)
        .swipeActions(edge: .leading) {
            Button("Not Spam") { Task { await decide(item, agree: false) } }.tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button("Spam") { Task { await decide(item, agree: true) } }.tint(.red)
        }
    }

    private func accountName(for accountId: UUID) -> String? {
        accounts.first { $0.id == accountId }?.name
    }

    private func decide(_ item: SpamReviewItem, agree: Bool) async {
        isDeciding = true
        try? await store.decide(item, agree: agree)
        isDeciding = false
    }

    private func runBulk(agree: Bool) async {
        let result = await store.decideAll(agree: agree)
        let toast: MVToast
        if result.failed > 0 {
            toast = MVToast(
                variant: .error,
                message: "\(result.failed) of \(result.attempted) could not be \(agree ? "confirmed" : "corrected")",
                duration: 0
            )
        } else {
            toast = MVToast(
                variant: .success,
                message: "\(result.succeeded) message\(result.succeeded == 1 ? "" : "s") "
                    + (agree ? "confirmed as spam" : "corrected")
            )
        }
        environment.toasts.show(toast)
    }
}

/// One review row — sender, Junk/account chips, subject, the model's reasoning, and the two
/// thumbs. Not `MailRowView`: the UX design gives this screen its own anatomy (no avatar, a
/// reasoning line instead of a snippet).
private struct SpamReviewRow: View {
    let item: SpamReviewItem
    let accountChip: String?
    let onConfirmSpam: () -> Void
    let onNotSpam: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(extractSenderName(item.fromAddr)).font(.subheadline).bold()
                if item.isJunk {
                    Chip(text: "Junk", tint: .orange)
                }
                if let accountChip {
                    Chip(text: accountChip, tint: .secondary)
                }
                Spacer()
                Text(MVDateFormat.relativeDate(item.receivedAt)).font(.caption).foregroundStyle(.secondary)
            }
            if let subject = item.subject {
                Text(subject).font(.subheadline)
            }
            if let reasoning = item.reasoning {
                Text(reasoning).font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                if let modelUsed = item.modelUsed {
                    Text(modelUsed).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button(action: onConfirmSpam) {
                    Label("Yes, spam", systemImage: MVSymbols.confirmVerdict).labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                Button(action: onNotSpam) {
                    Label("Not spam", systemImage: MVSymbols.correctVerdict).labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}
