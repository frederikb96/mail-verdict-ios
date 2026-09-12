import MailVerdictKit
import Push
import SwiftUI
import UIKit

/// New Mail Notifications: whether this iPhone is notified of new mail, which folders notify, this
/// device's name, and every other device registered with the server.
struct NotificationSettingsScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: NotificationSettingsStore?

    var body: some View {
        Group {
            if let store {
                NotificationSettingsForm(store: store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("New Mail Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let store = PushCoordinator.shared.settingsStore(environment: environment, connection: connection)
            self.store = store
            await store.reload()
        }
        .onChange(of: store?.notice) { _, notice in
            guard let notice else { return }
            environment.toasts.show(MVToast(variant: notice.isError ? .error : .success, message: notice.text))
            store?.notice = nil
        }
        #if DEBUG
            .screenshotReady(route: .notificationSettings, environment: environment, connection: connection)
        #endif
    }
}

private struct NotificationSettingsForm: View {
    @Bindable var store: NotificationSettingsStore
    @Environment(\.openURL) private var openURL
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            statusSection
            if showsPreferences {
                nameSection
                if store.status == .registered {
                    channelSection
                }
                folderSections
            }
            if !store.otherDevices.isEmpty {
                otherDevicesSection
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.reload() }
        .onChange(of: nameFocused) { _, focused in
            guard !focused else { return }
            Task { await store.commitLabel() }
        }
        .accessibilityIdentifier("notification-settings")
    }

    /// A server that cannot send has nothing to configure; only the device list still means
    /// something there.
    private var showsPreferences: Bool {
        switch store.status {
        case .loading, .loadFailed, .serverTooOld, .unavailable, .relayNotAllowed: return false
        case .notDetermined, .denied, .off, .registering, .registered, .failed: return true
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            switch store.status {
            case .loading:
                ProgressView()
            case .loadFailed(let message):
                Text(message)
                Button("Try Again") { Task { await store.reload() } }
            case .serverTooOld:
                Text("Update your MailVerdict server to enable notifications.")
            case .unavailable(let reason):
                Text("This server has no push notifications configured yet.")
                if let reason {
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
            case .relayNotAllowed:
                Text("This server does not allow this app's push relay.")
                Text("Its push.apns_relay_urls setting needs to list \(PushRegistrationService.relayURL).")
                    .font(.footnote).foregroundStyle(.secondary)
            case .notDetermined:
                Text("Turn on notifications for new mail")
                Button("Allow Notifications") { Task { await store.allow() } }
            case .denied:
                Text("Notifications are off for MailVerdict in iOS Settings")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            case .off:
                Text("This iPhone is not notified of new mail from this server.")
                Button("Turn On") { store.turnOn() }
            case .registering:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Turning on notifications…")
                }
            case .registered:
                Text("This iPhone receives a notification for new mail even when MailVerdict isn't open")
                Button("Send Test Notification") { Task { await store.sendTest() } }
                Button("Turn Off", role: .destructive) { Task { await store.turnOff() } }
            case .failed(let message):
                Text("Notifications could not be turned on: \(message)")
                Button("Try Again") { store.turnOn() }
            }
        }
    }

    private var nameSection: some View {
        Section {
            TextField("iPhone", text: $store.label)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { Task { await store.commitLabel() } }
        } header: {
            Text("This Device's Name")
        } footer: {
            Text("How this iPhone appears in the device list, here and in the web app.")
        }
    }

    private var channelSection: some View {
        Section("Notify About") {
            ForEach(PushChannel.allCases, id: \.self) { channel in
                Toggle(
                    channel.title,
                    isOn: Binding(
                        get: { store.isChannelEnabled(channel) },
                        set: { enabled in Task { await store.setChannel(channel, enabled: enabled) } }
                    ))
            }
        }
    }

    @ViewBuilder
    private var folderSections: some View {
        Section {
            Button(store.allFoldersEnabled ? "Deselect All" : "Select All") {
                Task { await store.toggleAll() }
            }
        } header: {
            Text("Notify for These Folders")
        } footer: {
            Text(
                "Unless you choose otherwise, every folder mail arrives in notifies — not Sent, Drafts, Trash or Junk.")
        }
        ForEach(store.groups) { group in
            Section(group.accountName) {
                Toggle(
                    "Notify for This Account",
                    isOn: Binding(
                        get: { store.isAccountEnabled(group.accountId) },
                        set: { on in Task { await store.setAccount(group.accountId, on: on) } }
                    ))
                ForEach(group.folders) { folder in
                    folderRow(folder)
                }
            }
        }
    }

    private func folderRow(_ folder: FolderResponse) -> some View {
        let enabled = store.isFolderEnabled(folder.id)
        return Button {
            Task { await store.toggleFolder(folder.id, on: !enabled) }
        } label: {
            HStack {
                Text(folder.displayName ?? folder.imapName)
                    .foregroundStyle(.primary)
                Spacer()
                if enabled {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(enabled ? .isSelected : [])
    }

    private var otherDevicesSection: some View {
        Section("Other Devices") {
            ForEach(store.otherDevices) { device in
                let isPhone = device.transport == .apns
                HStack(spacing: 12) {
                    Image(systemName: isPhone ? "iphone" : "desktopcomputer")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.label ?? (isPhone ? "iPhone" : "Unnamed device"))
                        HStack(spacing: 6) {
                            if device.failedAt != nil {
                                Text("unreachable").foregroundStyle(.red)
                            }
                            Text(device.lastSeenAt.map { "Last seen \(MVDateFormat.relativeAgo($0))" } ?? "Never seen")
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { Task { await store.remove(device) } }
                }
            }
        }
    }
}
