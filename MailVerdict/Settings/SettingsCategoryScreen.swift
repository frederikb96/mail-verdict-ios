import Foundation
import MailVerdictKit
import SwiftUI

/// One generic server-settings category — the server renders its fields by JSON type, and this
/// is the iOS equivalent: an order-preserving, labelled field list with the right control per
/// value kind, each committing its own `PUT` the moment it changes.
struct SettingsCategoryScreen: View {
    let category: String
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVSettingsCategoryStore?
    /// Shared by every field on the screen, keyed by `MVSettingsField.key` — the one signal each
    /// field's own blur-commit watches, and what `.onDisappear` clears to flush whichever field
    /// was still focused when the screen is left.
    @FocusState private var focusedFieldKey: String?

    private var resolvedCategory: MVSettingsCategory? { MVSettingsCategory(rawValue: category) }

    var body: some View {
        Group {
            if let resolvedCategory {
                CategoryForm(
                    category: resolvedCategory, store: store, environment: environment,
                    focusedFieldKey: $focusedFieldKey
                )
                .onDisappear { focusedFieldKey = nil }
                .task {
                    #if DEBUG
                        DebugLogBuffer.shared.append(.info, "screenshot", "settings-category-ai: screen task start")
                    #endif
                    guard store == nil else { return }
                    let freshStore = MVSettingsCategoryStore(
                        category: resolvedCategory, apiClient: connection.apiClient)
                    store = freshStore
                    #if DEBUG
                        SettingsDebugServices.shared.activeSettingsCategoryStore = freshStore
                        DebugLogBuffer.shared.append(
                            .info, "screenshot", "settings-category-ai: store created, loading")
                    #endif
                    await freshStore.load()
                    #if DEBUG
                        DebugLogBuffer.shared.append(
                            .info, "screenshot", "settings-category-ai: load() returned, state=\(freshStore.state)")
                    #endif
                }
            } else {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    message: "This app and the server may be running different versions."
                )
            }
        }
        .navigationTitle(resolvedCategory?.displayTitle ?? category.capitalized)
        .accessibilityIdentifier("settings-category-\(category)")
        #if DEBUG
            .screenshotReady(route: .settingsCategory(category), environment: environment, connection: connection)
        #endif
    }
}

private struct CategoryForm: View {
    let category: MVSettingsCategory
    let store: MVSettingsCategoryStore?
    let environment: AppEnvironment
    var focusedFieldKey: FocusState<String?>.Binding

    var body: some View {
        Form {
            if let store {
                switch store.state {
                case .loading:
                    ProgressView()
                case .failed(let error):
                    ErrorStateView(error: error) { Task { await store.load() } }
                case .loaded:
                    if category == .ai {
                        Section {
                            ForEach(MVSettingsProvider.allCases, id: \.self) { provider in
                                ProviderKeyRow(store: store, provider: provider, environment: environment)
                            }
                        } footer: {
                            Text(
                                "Keys are encrypted at rest and never shown again once saved — "
                                    + "clearing one falls back to the matching environment variable, if set."
                            )
                        }
                    }
                    if store.fields.isEmpty {
                        Text("No settings in this category")
                            .foregroundStyle(.secondary)
                    } else {
                        Section {
                            ForEach(store.fields) { field in
                                SettingsFieldRow(
                                    store: store, field: field, environment: environment,
                                    focusedFieldKey: focusedFieldKey)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One field, with the control its value kind calls for — a direct port of the web's
/// `SettingField` dispatch by JS type.
private struct SettingsFieldRow: View {
    let store: MVSettingsCategoryStore
    let field: MVSettingsField
    let environment: AppEnvironment
    var focusedFieldKey: FocusState<String?>.Binding

    var body: some View {
        switch field.kind {
        case .bool(let value):
            Toggle(MVSettingsLabels.label(for: field.key), isOn: Binding(get: { value }, set: { commit(.bool($0)) }))
        case .int(let value):
            IntFieldControl(
                label: MVSettingsLabels.label(for: field.key), key: field.key, value: value,
                focusedFieldKey: focusedFieldKey
            ) { commit(.int($0)) }
        case .float(let value):
            FloatFieldControl(
                label: MVSettingsLabels.label(for: field.key), key: field.key, value: value,
                focusedFieldKey: focusedFieldKey
            ) { commit(.float($0)) }
        case .string(let value):
            if field.key == "default_strictness" {
                StrictnessPicker(label: MVSettingsLabels.label(for: field.key), value: value) {
                    commit(.string($0))
                }
            } else {
                StringFieldControl(
                    label: MVSettingsLabels.label(for: field.key), key: field.key, value: value,
                    focusedFieldKey: focusedFieldKey
                ) { commit(.string($0)) }
            }
        case .json(let text):
            NavigationLink {
                JSONFieldEditor(label: MVSettingsLabels.label(for: field.key), text: text) { commit(.json($0)) }
            } label: {
                LabeledContent(MVSettingsLabels.label(for: field.key)) { Text("Edit JSON…") }
            }
        case .null:
            LabeledContent(MVSettingsLabels.label(for: field.key)) { Text("Not set").foregroundStyle(.secondary) }
        }
    }

    private func commit(_ kind: MVSettingsField.Kind) {
        Task {
            do {
                try await store.updateField(key: field.key, kind: kind)
            } catch {
                environment.toasts.show(.init(variant: .error, message: "Could not save: \(error.mvUserMessage)"))
            }
        }
    }
}

private struct IntFieldControl: View {
    let label: String
    let key: String
    let value: Int
    var focusedFieldKey: FocusState<String?>.Binding
    let onCommit: (Int) -> Void

    @State private var text: String = ""

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .focused(focusedFieldKey, equals: key)
                .toolbar { keyboardDoneToolbar }
                .onSubmit { submitIfValid() }
            Stepper(
                // `Int.min...Int.max` traps: `Stepper` computes the range's distance, and
                // `Int.max - Int.min` overflows `Int`. A billion in either direction is still far
                // past anything a server-settings integer (`max_tokens`, a retry count, …) holds.
                "", value: Binding(get: { value }, set: { onCommit($0) }), in: -1_000_000_000...1_000_000_000
            )
            .labelsHidden()
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { _, newValue in text = String(newValue) }
        .onChange(of: focusedFieldKey.wrappedValue) { old, new in
            if old == key, new != key { submitIfValid() }
        }
    }

    @ToolbarContentBuilder
    private var keyboardDoneToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { focusedFieldKey.wrappedValue = nil }
        }
    }

    private func submitIfValid() {
        guard let parsed = Int(text) else {
            text = String(value)
            return
        }
        onCommit(parsed)
    }
}

private struct FloatFieldControl: View {
    let label: String
    let key: String
    let value: Double
    var focusedFieldKey: FocusState<String?>.Binding
    let onCommit: (Double) -> Void

    @State private var text: String = ""

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .focused(focusedFieldKey, equals: key)
                .toolbar { keyboardDoneToolbar }
                .onSubmit { submitIfValid() }
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { _, newValue in text = String(newValue) }
        .onChange(of: focusedFieldKey.wrappedValue) { old, new in
            if old == key, new != key { submitIfValid() }
        }
    }

    @ToolbarContentBuilder
    private var keyboardDoneToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { focusedFieldKey.wrappedValue = nil }
        }
    }

    private func submitIfValid() {
        guard let parsed = Double(text) else {
            text = String(value)
            return
        }
        onCommit(parsed)
    }
}

private struct StringFieldControl: View {
    let label: String
    let key: String
    let value: String
    var focusedFieldKey: FocusState<String?>.Binding
    let onCommit: (String) -> Void

    @State private var text: String = ""

    private var isSecure: Bool {
        let lowered = key.lowercased()
        return lowered.contains("key") || lowered.contains("password") || lowered.contains("secret")
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if isSecure {
                SecureField("", text: $text)
                    .multilineTextAlignment(.trailing)
                    .focused(focusedFieldKey, equals: key)
                    .onSubmit { onCommit(text) }
            } else {
                TextField("", text: $text)
                    .multilineTextAlignment(.trailing)
                    .focused(focusedFieldKey, equals: key)
                    .onSubmit { onCommit(text) }
            }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, newValue in text = newValue }
        .onChange(of: focusedFieldKey.wrappedValue) { old, new in
            if old == key, new != key { onCommit(text) }
        }
    }
}

private struct StrictnessPicker: View {
    let label: String
    let value: String
    let onCommit: (String) -> Void

    var body: some View {
        Picker(
            label,
            selection: Binding(
                get: { MVSemanticStrictness(rawValue: value) ?? .balanced },
                set: { onCommit($0.rawValue) }
            )
        ) {
            Text("Loose").tag(MVSemanticStrictness.loose)
            Text("Balanced").tag(MVSemanticStrictness.balanced)
            Text("Strict").tag(MVSemanticStrictness.strict)
        }
    }
}

private struct JSONFieldEditor: View {
    let label: String
    @State var text: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isValid = true

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
                    .onChange(of: text) { _, newValue in
                        isValid =
                            (try? JSONSerialization.jsonObject(with: Data(newValue.utf8), options: [.fragmentsAllowed]))
                            != nil
                    }
                if !isValid {
                    Text("This isn't valid JSON.").foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .navigationTitle(label)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
    }
}

private struct ProviderKeyRow: View {
    let store: MVSettingsCategoryStore
    let provider: MVSettingsProvider
    let environment: AppEnvironment

    @State private var text: String = ""
    @State private var isSaving = false

    private var status: MVProviderKeyStatus? { store.providerStatus[provider] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(provider.label).font(.subheadline.weight(.medium))
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                SecureField(status?.configured == true ? "Replace key" : "Paste key", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") { Task { await save(text) } }
                    .disabled(text.isEmpty || isSaving)
                if status?.configured == true {
                    Button("Clear", role: .destructive) { Task { await save("") } }
                        .disabled(isSaving)
                }
            }
        }
        .accessibilityIdentifier("settings-provider-key-\(provider.rawValue)")
    }

    private var statusText: String {
        guard let status else { return "not configured" }
        if status.configured {
            return "configured (…\(status.hint ?? ""))"
        }
        return "not configured"
    }

    private func save(_ value: String) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.setProviderKey(provider, value: value)
            text = ""
        } catch {
            environment.toasts.show(
                .init(
                    variant: .error,
                    message: "Could not save the \(provider.label) key: \(error.mvUserMessage)"))
        }
    }
}
