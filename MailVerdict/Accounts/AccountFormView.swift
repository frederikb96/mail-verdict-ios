import MailVerdictKit
import SwiftUI

/// Add/edit account sheet, shared by the Accounts list ("Add Account") and Account Detail
/// ("Edit…") — a direct port of the web's `AccountForm`, including which fields lock once the
/// account exists.
struct AccountFormView: View {
    enum Mode {
        case create
        case edit(AccountResponse)
    }

    let mode: Mode
    let onSave: (MVAccountFormInput) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input: MVAccountFormInput
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(mode: Mode, onSave: @escaping (MVAccountFormInput) async throws -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create:
            _input = State(initialValue: MVAccountFormInput())
        case .edit(let account):
            _input = State(initialValue: MVAccountFormInput(account: account))
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                form
                    #if DEBUG
                        .onChange(of: AccountsDebugServices.shared.scrollToGlacierSectionRequested) { _, requested in
                            guard requested else { return }
                            proxy.scrollTo(Self.glacierSectionId, anchor: .top)
                            AccountsDebugServices.shared.glacierSectionScrolled = true
                        }
                    #endif
            }
            .navigationTitle(isEditing ? "Edit Account" : "Add Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Update" : "Create") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
        }
    }

    /// Read by the `account-edit-glacier` screenshot entry, which the fields below the fold in an
    /// ordinary Form are otherwise invisible to.
    private static let glacierSectionId = "account-form-glacier-section"

    private var form: some View {
        Form {
            Section("Account Name") {
                TextField("My Email", text: $input.name)
            }

            Section {
                TextField("imap.example.com", text: $input.imapHost).disabled(isEditing)
                TextField("Port", text: $input.imapPort).keyboardType(.numberPad).disabled(isEditing)
                TextField("user@example.com", text: $input.imapUser).disabled(isEditing)
                SecureField(isEditing ? "(unchanged)" : "Password", text: $input.imapPassword)
            } header: {
                Text("IMAP")
            } footer: {
                if isEditing {
                    Text(
                        "IMAP host, port and user can't be changed on an existing account — "
                            + "delete and re-add it to connect to a different server.")
                }
            }

            Section("SMTP") {
                TextField("smtp.example.com", text: $input.smtpHost)
                TextField("Port", text: $input.smtpPort).keyboardType(.numberPad)
                TextField("SMTP user", text: $input.smtpUser)
                SecureField(isEditing ? "(unchanged)" : "Password", text: $input.smtpPassword)
            }

            Section {
                Toggle("Enable spam detection", isOn: $input.spamEnabled)
                Toggle("Bundle orders and tickets", isOn: $input.ordersEnabled)
            }

            Section("Trash retention (days)") {
                TextField("Off — Trash is never emptied automatically", text: $input.trashRetentionDays)
                    .keyboardType(.numberPad)
            }

            Section("Junk retention (days)") {
                TextField("Off — Junk is never emptied automatically", text: $input.junkRetentionDays)
                    .keyboardType(.numberPad)
            }

            if isEditing {
                Section {
                    Toggle("Enable glacier storage", isOn: $input.glacierEnabled)
                    TextField(
                        "Off — move mail into the glacier by hand only", text: $input.glacierAutoDays
                    )
                    .keyboardType(.numberPad)
                    Text(
                        "Automatically move archived mail into the glacier once it is this many days old. "
                            + "Left blank, mail only moves into the glacier by hand."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Glacier")
                } footer: {
                    Text(
                        "A place mail can be moved to that leaves this account's mail server for good "
                            + "and lives on only here. Can't be turned off again while it holds anything."
                    )
                }
                .id(Self.glacierSectionId)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(input)
            dismiss()
        } catch {
            errorMessage = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case MVAccountFormError.missingName: return "Enter an account name."
        case MVAccountFormError.missingImapHost: return "Enter an IMAP host."
        case MVAccountFormError.missingImapUser: return "Enter an IMAP user."
        case MVAccountFormError.invalidImapPort: return "The IMAP port must be a positive number."
        case MVAccountFormError.invalidSmtpPort: return "The SMTP port must be a positive number."
        case MVAccountFormError.invalidTrashRetention, MVAccountFormError.invalidJunkRetention:
            return "Retention must be at least 1 day, or left blank for Off."
        case MVAccountFormError.invalidGlacierAutoDays:
            return "The automatic sweep must be at least 1 day, or left blank for manual only."
        default: return error.mvUserMessage
        }
    }
}
