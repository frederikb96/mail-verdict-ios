import Foundation

/// Per-field labels and sort order for the generic settings renderer — a direct port of the web's
/// `SETTING_LABELS` map and its ordering rule ("labelled keys in this order, then anything else
/// alphabetically"), since several categories share a field name with the same meaning
/// (`provider`, `model`, `max_attempts`, …) and this is one map for all of them rather than one
/// per category.
public enum MVSettingsLabels {

    /// Declaration order here is the render order for any key it names.
    public static let order: [String] = [
        "provider",
        "model",
        "base_url",
        "reasoning_effort",
        "max_tokens",
        "max_retries",
        "base_delay_seconds",
        "max_delay_seconds",
        "exponential_base",
        "lease_seconds",
        "poll_interval_seconds",
        "max_attempts",
        "unavailable_probe_seconds",
        "live_max_age_days",
        "enabled",
        "content_chars",
        "batch_size",
        "neighbor_k",
        "neighbor_min_similarity",
        "default_strictness",
        "default_event_duration_minutes",
        "default_reminder_minutes",
        "undo_send_seconds",
        "mark_read_on_file_to_archive_or_junk",
        "bell_badge_counts_new_mail",
        "notify_wait_seconds",
        "language",
        "filter",
    ]

    private static let labels: [String: String] = [
        "provider": "Provider",
        "model": "Model",
        "base_url": "Server address (custom provider only)",
        "reasoning_effort": "Reasoning effort",
        "max_tokens": "Max tokens",
        "max_retries": "Max retries",
        "base_delay_seconds": "Base retry delay (seconds)",
        "max_delay_seconds": "Max retry delay (seconds)",
        "exponential_base": "Retry backoff multiplier",
        "lease_seconds": "Worker lease (seconds)",
        "poll_interval_seconds": "Poll interval (seconds)",
        "max_attempts": "Max attempts",
        "unavailable_probe_seconds": "Retry after unavailable (seconds)",
        "live_max_age_days": "Ignore mail older than (days)",
        "enabled": "Enabled",
        "content_chars": "Characters embedded per message",
        "batch_size": "Backfill batch size",
        "neighbor_k": "Similar past messages consulted",
        "neighbor_min_similarity": "Minimum similarity",
        "default_strictness": "Default strictness",
        "default_event_duration_minutes": "Default event duration (minutes)",
        "default_reminder_minutes": "Default reminder (minutes)",
        "undo_send_seconds": "Undo window after Send (seconds)",
        "mark_read_on_file_to_archive_or_junk": "Mark read when filed to Archive or Junk",
        "bell_badge_counts_new_mail": "Bell badge counts new mail",
        "notify_wait_seconds": "Wait before notifying (seconds)",
        "language": "Language of titles and summaries",
        "filter": "First filter (patterns)",
    ]

    /// `SETTING_LABELS[key]` if named, otherwise `humanized(key)` — display text only; the field's
    /// own key is what every write still uses.
    public static func label(for key: String) -> String {
        labels[key] ?? humanized(key)
    }

    /// A raw key read as a sentence — `"notify_wait_seconds"` → `"Notify wait seconds"` — for any
    /// key `labels` doesn't name, so a newly added server setting still renders as something
    /// readable rather than nothing.
    public static func humanized(_ key: String) -> String {
        let parts = key.split(separator: "_")
        guard let first = parts.first else { return key }
        let capitalizedFirst = first.prefix(1).uppercased() + first.dropFirst()
        return ([String(capitalizedFirst)] + parts.dropFirst().map(String.init)).joined(separator: " ")
    }
}

extension MVSettingsCategory {
    /// The screen title for this category's generic form — "Filing and Notifications" for `mail`
    /// rather than a bare capitalised key, matching the card headings on the web's settings page.
    public var displayTitle: String {
        switch self {
        case .ai: return "AI"
        case .semantic: return "Semantic Search"
        case .retry: return "Retry"
        case .pipeline: return "Pipeline"
        case .outbox: return "Outbox"
        case .mail: return "Filing and Notifications"
        case .orders: return "Orders"
        }
    }
}

/// Which fields a category's GET response carries that the generic renderer must never draw as an
/// editable field. `ai`'s write-only key status is computed on every read and stripped from any
/// write (`settings_api.py`'s `_AI_COMPUTED_FIELDS`). `semantic`'s active_model/active_provider/
/// active_base_url are managed by the backend's backfill reconciler during a re-embed
/// (`embeddings/worker.py`'s `_maybe_cutover`), never something to type into. `calendar` has its
/// own computed field (`default_calendar_id`) but calendar settings are out of this app's scope
/// entirely, so there is nothing to exclude it from.
public enum MVSettingsComputedFields {
    private static let semanticManaged: Set<String> = [
        "active_model", "active_provider", "active_base_url",
    ]

    public static func excluded(for category: MVSettingsCategory) -> Set<String> {
        switch category {
        case .ai:
            var excluded: Set<String> = []
            for provider in MVSettingsProvider.allCases {
                excluded.insert("\(provider.rawValue)_api_key_configured")
                excluded.insert("\(provider.rawValue)_api_key_hint")
            }
            return excluded
        case .semantic:
            return semanticManaged
        default:
            return []
        }
    }
}
