import MailVerdictKit
import SwiftUI

/// The bell — Mail and System tabs.
struct NotificationsScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: NotificationsStore
    @State private var accounts: [AccountResponse] = []
    @State private var tab: Tab = .mail

    private enum Tab: String, CaseIterable {
        case mail = "Mail"
        case system = "System"
    }

    init(environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.environment = environment
        self.connection = connection
        self._store = State(initialValue: NotificationsStore(apiClient: connection.apiClient))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            content
        }
        .navigationTitle("Notifications")
        .toolbar {
            if hasSomethingToDismissInCurrentTab {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Dismiss All") { Task { await dismissAllInCurrentTab() } }
                }
            }
        }
        .task {
            #if DEBUG
                NotificationsFixtures.activeStore = store
            #endif
            store.subscribeToLive(connection.liveEventHub)
            accounts = (try? await connection.apiClient.listAccounts()) ?? []
            await store.load()
        }
        .onDisappear { store.unsubscribeFromLive(connection.liveEventHub) }
        #if DEBUG
            .screenshotReady(route: .notifications, environment: environment, connection: connection)
        #endif
    }

    private var hasSomethingToDismissInCurrentTab: Bool {
        switch tab {
        case .mail: return !store.mailAlerts.isEmpty
        case .system: return !store.notifications.isEmpty || !store.systemAlerts.isEmpty
        }
    }

    private func dismissAllInCurrentTab() async {
        switch tab {
        case .mail: await store.dismissAllMailAlerts()
        case .system: await store.dismissAllSystem()
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.mailAlerts.isEmpty && store.notifications.isEmpty {
            ProgressView()
        } else {
            switch tab {
            case .mail: mailTab
            case .system: systemTab
            }
        }
    }

    private var mailTab: some View {
        Group {
            if store.mailAlerts.isEmpty {
                EmptyStateView(systemImage: MVSymbols.bell, message: "Nothing yet")
            } else {
                List {
                    ForEach(store.mailAlerts) { alert in
                        Button {
                            openAlert(alert)
                        } label: {
                            AlertRow(alert: alert, accountName: accountName(for: alert.accountId))
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Dismiss") { Task { await store.dismissAlert(alert.id) } }
                        }
                    }
                }
            }
        }
    }

    private var systemTab: some View {
        Group {
            if store.systemAlerts.isEmpty && store.notifications.isEmpty {
                EmptyStateView(systemImage: MVSymbols.bell, message: "Nothing to report")
            } else {
                List {
                    ForEach(store.systemAlerts) { alert in
                        Button {
                            openAlert(alert)
                        } label: {
                            AlertRow(alert: alert, accountName: accountName(for: alert.accountId))
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Dismiss") { Task { await store.dismissAlert(alert.id) } }
                        }
                    }
                    ForEach(store.notifications) { notification in
                        SystemNotificationRow(
                            notification: notification, accountName: accountName(for: notification.accountId)
                        )
                        .swipeActions {
                            Button("Dismiss") {
                                Task {
                                    await store.acknowledgeNotification(
                                        accountId: notification.accountId, notificationId: notification.id
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func accountName(for accountId: UUID?) -> String? {
        guard accounts.count > 1, let accountId else { return nil }
        return accounts.first { $0.id == accountId }?.name
    }

    private func openAlert(_ alert: AlertResponse) {
        Task {
            let resolver = MVMessagePlaceResolver(apiClient: connection.apiClient)
            // `alert.url` (a non-mail kind with nowhere else to go) has no iOS route to open —
            // the web's `router.push(alert.url)` targets a web-only path. Nothing in scope for
            // this run has a non-mail alert kind that sets it, so this stays unhandled rather
            // than faking a destination.
            guard let resolution = await store.resolveAndDismiss(alert, resolver: resolver) else { return }
            switch resolution {
            case .route(let routes):
                environment.navigationPath.append(contentsOf: routes)
            case .notFound(let toastMessage):
                environment.toasts.show(MVToast(variant: .error, message: toastMessage))
            }
        }
    }
}

private struct AlertRow: View {
    let alert: AlertResponse
    let accountName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(alert.title ?? "(no subject)").font(.subheadline).lineLimit(1)
                Spacer()
                Text(MVDateFormat.relativeDate(alert.deliveredAt ?? alert.createdAt)).font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let body = alert.body {
                Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let accountName {
                Chip(text: accountName, tint: .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SystemNotificationRow: View {
    let notification: NotificationResponse
    let accountName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(NotificationsSupport.actionLabel(for: notification.action)) failed").font(.subheadline)
                Spacer()
                Text(MVDateFormat.relativeDate(notification.createdAt)).font(.caption).foregroundStyle(.secondary)
            }
            if let error = notification.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if notification.revertedAt == nil {
                Text("Our value is still shown as applied — the server never got it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let accountName {
                Chip(text: accountName, tint: .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
