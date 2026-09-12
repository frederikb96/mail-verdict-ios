import Foundation

/// Builds a JSON literal for exactly one scalar value — the building block for the handful of
/// PATCH bodies this package writes by hand rather than through a typed `Encodable` request.
///
/// It exists because several backend routes read their request with Pydantic's
/// `model_dump(exclude_unset=True)`, which distinguishes a field that was never present in the
/// JSON from one explicitly set to `null` — "leave unchanged" versus "clear it". Swift's
/// synthesized `Encodable` cannot express that distinction: an `Optional` property it encodes
/// always *omits* the key when the value is `nil`, so a typed request can set a field but can
/// never clear one back to null on a route that relies on the field being absent to mean
/// "untouched". Building the body as text is what makes "send literal `null`" and "omit the key
/// entirely" two different, chosen things again.
public enum MVJSONLiteral {
    public static func string(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode([value]) else { return "\"\"" }
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("["), text.hasSuffix("]") else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    public static func optionalString(_ value: String?) -> String {
        guard let value else { return "null" }
        return string(value)
    }

    public static func int(_ value: Int) -> String {
        String(value)
    }

    public static func optionalInt(_ value: Int?) -> String {
        guard let value else { return "null" }
        return String(value)
    }

    public static func bool(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}

extension Array {
    /// `Array.move(fromOffsets:toOffset:)`'s own shape — `List.onMove` hands a screen exactly
    /// this pair — but that method itself lives in SwiftUI, not the standard library, so a
    /// package store a Linux test drives directly needs its own copy. `destination` is an index
    /// into the array as it stood *before* removal; the subtraction below is what keeps the
    /// insertion point correct once the moved elements are gone from ahead of it.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        for offset in source.sorted(by: >) {
            remove(at: offset)
        }
        insert(contentsOf: moving, at: Swift.max(0, Swift.min(adjustedDestination, count)))
    }
}
