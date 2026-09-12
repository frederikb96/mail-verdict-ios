import Foundation
import Observation

/// One server settings category's generic form — `GET`s the category, orders and labels its
/// fields (`MVSettingsLabels`), and commits each field's edit with its own `PUT` the instant it
/// changes, per the UX design's "changes apply immediately, per field; there is no Save button".
///
/// Every write is optimistic: the field updates locally before the request resolves, and
/// `updateField` reverts it and rethrows on failure, so the caller's own catch is what turns that
/// into an error toast — this store only ever speaks in field values, never in UI.
@Observable
@MainActor
public final class MVSettingsCategoryStore {
    public enum LoadState: Equatable {
        case loading
        case loaded
        case missing
        case failed(String)
    }

    public private(set) var fields: [MVSettingsField] = []
    public private(set) var providerStatus: [MVSettingsProvider: MVProviderKeyStatus] = [:]
    public private(set) var state: LoadState = .loading

    public let category: MVSettingsCategory
    private let apiClient: MVApiClient

    public init(category: MVSettingsCategory, apiClient: MVApiClient) {
        self.category = category
        self.apiClient = apiClient
    }

    public func load() async {
        state = .loading
        do {
            let data = try await apiClient.getSettings(category: category)
            try apply(data)
            state = .loaded
        } catch {
            state = .failed((error as? MVError)?.userMessage ?? "\(error)")
        }
    }

    /// Parses a response body into this store's `fields`/`providerStatus` — split out from
    /// `load()` so a test can feed it fixture bytes with no network involved.
    func apply(_ data: Data) throws {
        let parsed = try MVOrderedSettingsParser.parse(data)
        let excluded = MVSettingsComputedFields.excluded(for: category)

        if category == .ai {
            var status: [MVSettingsProvider: MVProviderKeyStatus] = [:]
            for provider in MVSettingsProvider.allCases {
                let configured: Bool = {
                    guard
                        case .bool(let value) = parsed.first(where: {
                            $0.key == "\(provider.rawValue)_api_key_configured"
                        })?.kind
                    else { return false }
                    return value
                }()
                let hint: String? = {
                    guard
                        case .string(let value) = parsed.first(where: { $0.key == "\(provider.rawValue)_api_key_hint" }
                        )?.kind
                    else { return nil }
                    return value
                }()
                status[provider] = MVProviderKeyStatus(configured: configured, hint: hint)
            }
            providerStatus = status
        } else {
            providerStatus = [:]
        }

        let filtered = parsed.filter {
            $0.key != "id" && $0.key != "category" && !excluded.contains($0.key)
        }
        let labelled = filtered.filter { MVSettingsLabels.order.contains($0.key) }
            .sorted {
                MVSettingsLabels.order.firstIndex(of: $0.key)!
                    < MVSettingsLabels.order.firstIndex(of: $1.key)!
            }
        let unlabelled = filtered.filter { !MVSettingsLabels.order.contains($0.key) }
            .sorted { $0.key < $1.key }
        fields = (labelled + unlabelled).map { MVSettingsField(key: $0.key, kind: $0.kind) }
    }

    /// Commits one field's new value immediately — optimistic update, `PUT`, revert on failure.
    @discardableResult
    public func updateField(key: String, kind: MVSettingsField.Kind) async throws -> Bool {
        guard let index = fields.firstIndex(where: { $0.key == key }) else { return false }
        let previous = fields[index].kind
        fields[index].kind = kind
        do {
            let body = try MVOrderedSettingsParser.singleFieldBody(key: key, kind: kind)
            _ = try await apiClient.updateSettings(category: category, data: body)
            return true
        } catch {
            fields[index].kind = previous
            throw error
        }
    }

    /// Saves or clears one provider's API key — write-only, the field never appears in a GET to
    /// revert to, so there is nothing to roll back locally beyond re-fetching `providerStatus`.
    public func setProviderKey(_ provider: MVSettingsProvider, value: String) async throws {
        let body = try MVOrderedSettingsParser.singleFieldBody(
            key: "\(provider.rawValue)_api_key", kind: .string(value))
        _ = try await apiClient.updateSettings(category: category, data: body)
        await load()
    }
}
