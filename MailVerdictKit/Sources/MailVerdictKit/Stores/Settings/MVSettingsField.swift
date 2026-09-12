import Foundation

/// One field the generic settings renderer draws, in the order it should appear.
///
/// `Dictionary` and `JSONSerialization` both throw away two things the renderer needs: the order
/// fields were written in, and whether a number literal carried a fraction (`1` decodes the same
/// as `1.0` through either). `MVOrderedSettingsParser` recovers both by scanning the raw response
/// body itself rather than going through `Decodable`.
public struct MVSettingsField: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bool(Bool)
        case int(Int)
        case float(Double)
        case string(String)
        /// An object or array value — the generic renderer edits this as a single block of JSON
        /// text rather than drawing its members as fields, so the kind carries that text
        /// pre-validated and pretty-printed rather than a parsed structure nothing here reads.
        case json(String)
        case null
    }

    public var id: String { key }
    public let key: String
    public var kind: Kind

    public init(key: String, kind: Kind) {
        self.key = key
        self.kind = kind
    }
}

/// One provider's write-only API key status — the `{provider}_api_key_configured` /
/// `_hint` pair the `ai` category's GET response carries, read by `ProviderKeyField` and excluded
/// from the generic field list because the key itself never appears in a response to edit.
public struct MVProviderKeyStatus: Equatable, Sendable {
    public let configured: Bool
    public let hint: String?

    public init(configured: Bool, hint: String?) {
        self.configured = configured
        self.hint = hint
    }
}

/// `anthropic` / `openai` — the providers `ai` settings holds a key for (`PROVIDER_ENV_VARS` in
/// the backend's credentials module). A new provider needs a case added here; nothing else in
/// this package hardcodes the pair.
public enum MVSettingsProvider: String, CaseIterable, Sendable {
    case anthropic
    case openai

    public var label: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }
}
