import Foundation

/// Pydantic's `Field(default=…)`/`Field(default_factory=…)` means "omit this and the server
/// fills it in" — not required in the OpenAPI schema, but never optional from the app's own point
/// of view: the value always exists, it just might not have been sent this time. A plain
/// non-optional Swift property fails to decode the moment a server genuinely omits one (or
/// `ContractTests`' minimal instance, which always omits a non-required field, simulating exactly
/// that). `@MVDefaulted<Source>` decodes the field when present and falls back to `Source`'s own
/// default when it is not, so the Swift type stays non-optional — which is what every caller
/// actually wants, a boolean flag or a count is never legitimately "absent" — without ever
/// crashing on a response that left the field out.
public protocol MVDefaultValueSource: Sendable {
    associatedtype Value: Codable & Equatable & Sendable
    static var defaultValue: Value { get }
}

@propertyWrapper
public struct MVDefaulted<Source: MVDefaultValueSource>: Sendable {
    public var wrappedValue: Source.Value

    public init(wrappedValue: Source.Value) {
        self.wrappedValue = wrappedValue
    }
}

extension MVDefaulted: Decodable where Source.Value: Decodable {
    public init(from decoder: Decoder) throws {
        self.wrappedValue = try Source.Value(from: decoder)
    }
}

extension MVDefaulted: Encodable where Source.Value: Encodable {
    public func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension MVDefaulted: Equatable where Source.Value: Equatable {}

extension KeyedDecodingContainer {
    /// The piece that actually makes a missing key fall back rather than throw — synthesized
    /// `Decodable` calls this overload for any property whose declared type is `MVDefaulted<_>`,
    /// ahead of the type's own plain `Decodable` conformance above.
    public func decode<Source: MVDefaultValueSource>(
        _ type: MVDefaulted<Source>.Type, forKey key: Key
    ) throws -> MVDefaulted<Source> where Source.Value: Decodable {
        try decodeIfPresent(MVDefaulted<Source>.self, forKey: key)
            ?? MVDefaulted(wrappedValue: Source.defaultValue)
    }
}

// MARK: - Default sources shared across models

public enum MVDefaultFalse: MVDefaultValueSource {
    public static let defaultValue = false
}

public enum MVDefaultTrue: MVDefaultValueSource {
    public static let defaultValue = true
}

public enum MVDefaultZero: MVDefaultValueSource {
    public static let defaultValue = 0
}

/// One generic source covers every empty-array default (`keywords`, `tags`, `attachments`, …) —
/// there is exactly one sensible default for "a list the server didn't send", so this needs no
/// per-field marker the way the two account-specific sources below do.
public struct MVDefaultEmptyArray<Element: Codable & Equatable & Sendable>: MVDefaultValueSource {
    public static var defaultValue: [Element] { [] }
}

/// `AccountCreateRequest.imap_port`'s own default (993, the standard IMAPS port) — the one
/// non-zero, non-boolean default in the registry, so it gets its own marker rather than widening
/// `MVDefaultZero` into something more general for a single call site.
public enum MVDefaultImapPort: MVDefaultValueSource {
    public static let defaultValue = 993
}

/// `AccountResponse.state`'s own default — the lifecycle state column starts here before
/// PostIMAP ever writes to it.
public enum MVDefaultAccountStateCreated: MVDefaultValueSource {
    public static let defaultValue = "created"
}
