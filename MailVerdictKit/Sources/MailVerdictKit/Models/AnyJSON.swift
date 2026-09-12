import Foundation

/// A handful of backend fields carry genuinely open-ended JSON — `Account.capabilities`, most
/// concretely, which nothing in this app renders and whose shape is PostIMAP's own to extend
/// freely. Unlike `MVJSONValue` (Models/JSONValue.swift, which names its two specific shapes),
/// this decodes (and re-encodes) *any* JSON value, for the fields no caller needs to inspect —
/// only to carry through without losing or rejecting whatever is actually there.
public enum MVAnyJSON: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: MVAnyJSON])
    case array([MVAnyJSON])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: MVAnyJSON].self) {
            self = .object(value)
        } else if let value = try? container.decode([MVAnyJSON].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
