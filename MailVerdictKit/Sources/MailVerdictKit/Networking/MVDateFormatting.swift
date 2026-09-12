import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Every timestamp the backend sends is Pydantic's own `datetime.isoformat()` — `"+00:00"` (or
/// another numeric offset), never a bare `Z`, and microseconds only when they are non-zero. The
/// default `JSONDecoder.dateDecodingStrategy.iso8601` formatter refuses the fractional-seconds
/// form outright, so every model with a `Date` field needs this rather than the stock strategy.
enum MVDateFormatting {
    // `ISO8601DateFormatter` is not `Sendable`, but every use here is `date(from:)`/`string(from:)`
    // on an already-configured instance — read-only from this type's own perspective, and Apple's
    // docs call the type thread-safe for exactly that pattern.
    nonisolated(unsafe) private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        withFractionalSeconds.date(from: string) ?? withoutFractionalSeconds.date(from: string)
    }

    /// Always with fractional seconds on encode — accepted by every form Pydantic parses back,
    /// and never loses precision a round trip (an undo-send countdown, most concretely) depends on.
    static func format(_ date: Date) -> String {
        withFractionalSeconds.string(from: date)
    }
}

extension JSONDecoder {
    /// The decoder every `MVApiClient` response goes through — `MVDateFormatting`'s date
    /// handling, shared rather than each call site configuring its own and inevitably drifting.
    public static let mvDefault: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = MVDateFormatting.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Not a recognized ISO-8601 date: \(raw)"
                )
            }
            return date
        }
        return decoder
    }()
}

extension JSONEncoder {
    /// The encoder every `MVApiClient` request body goes through.
    public static let mvDefault: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(MVDateFormatting.format(date))
        }
        return encoder
    }()
}
