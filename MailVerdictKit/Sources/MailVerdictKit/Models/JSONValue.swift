import Foundation

/// A handful of backend fields are typed `Any` in Python (`to_addrs`, `cc_addrs`, `bcc_addrs` on
/// `MessageSummary`/`MessageDetail`) because PostIMAP stores an address header as either a single
/// string or a JSON array depending on how the message arrived — there is no one Swift type that
/// decodes both. This is the generic "whatever JSON is there" value every other model in this
/// package avoids needing, confined to the handful of fields that actually are untyped wire-side.
public enum MVJSONValue: Sendable, Equatable, Codable {
    case string(String)
    case array([String])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String].self) {
            self = .array(value)
        } else {
            // An address field sent as something else entirely (a nested object, say) is still
            // not a reason to fail decoding the whole message — it falls back to empty.
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Every address the value names, whichever shape it arrived in — what a caller almost
    /// always actually wants rather than the shape itself.
    public var addresses: [String] {
        switch self {
        case .string(let value): return value.isEmpty ? [] : [value]
        case .array(let value): return value
        case .null: return []
        }
    }
}
