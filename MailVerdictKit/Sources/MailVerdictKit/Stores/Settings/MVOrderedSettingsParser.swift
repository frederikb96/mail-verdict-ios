import Foundation

public enum MVOrderedSettingsError: Error, Equatable {
    case notAnObject
    case malformed
}

/// Recovers what `Decodable`/`JSONSerialization` discard from a settings category's response
/// body: the order its top-level keys were written in, and whether a number literal carried a
/// fraction. It does not parse nested structures at all — an object or array value is captured as
/// its own raw substring and handed to `JSONSerialization` only to validate and pretty-print it,
/// because the generic renderer edits those as one block of JSON text, never as individual
/// fields, so nothing here ever needs their own key order.
public enum MVOrderedSettingsParser {

    /// `(key, kind)` pairs in response order — callers that need a different order (the generic
    /// renderer's label order, then alphabetical) re-sort this themselves rather than the parser
    /// picking an order nothing about parsing requires.
    public static func parse(_ data: Data) throws -> [(key: String, kind: MVSettingsField.Kind)] {
        var chars = Substring(String(decoding: data, as: UTF8.self))
        skipWhitespace(&chars)
        guard chars.first == "{" else { throw MVOrderedSettingsError.notAnObject }
        chars.removeFirst()
        skipWhitespace(&chars)

        var result: [(key: String, kind: MVSettingsField.Kind)] = []
        if chars.first == "}" { return result }

        while true {
            skipWhitespace(&chars)
            let key = try readQuotedString(&chars)
            skipWhitespace(&chars)
            guard chars.first == ":" else { throw MVOrderedSettingsError.malformed }
            chars.removeFirst()
            skipWhitespace(&chars)
            let rawValue = try readValueText(&chars)
            result.append((key: key, kind: try classify(rawValue)))
            skipWhitespace(&chars)
            guard let next = chars.first else { throw MVOrderedSettingsError.malformed }
            if next == "," {
                chars.removeFirst()
                continue
            }
            if next == "}" {
                chars.removeFirst()
                break
            }
            throw MVOrderedSettingsError.malformed
        }
        return result
    }

    // MARK: - Raw text extraction

    private static func skipWhitespace(_ chars: inout Substring) {
        while let first = chars.first, first.isWhitespace { chars.removeFirst() }
    }

    /// Consumes a JSON string literal, quotes included, and returns its unescaped content —
    /// reusing `JSONDecoder` for the actual unescaping (array-wrapped, so it never depends on
    /// whether this Foundation build accepts a bare top-level string fragment) rather than
    /// hand-rolling `\uXXXX` handling.
    private static func readQuotedString(_ chars: inout Substring) throws -> String {
        let token = try readQuotedToken(&chars)
        guard let data = "[\(token)]".data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data),
            let value = decoded.first
        else {
            throw MVOrderedSettingsError.malformed
        }
        return value
    }

    /// Consumes one JSON string literal and returns it verbatim, quotes included — the building
    /// block both key and value reading use, since the quoted form is what a later
    /// `JSONDecoder`/`JSONSerialization` pass needs anyway.
    private static func readQuotedToken(_ chars: inout Substring) throws -> String {
        guard chars.first == "\"" else { throw MVOrderedSettingsError.malformed }
        var token = "\""
        chars.removeFirst()
        var escaped = false
        while let c = chars.first {
            token.append(c)
            chars.removeFirst()
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                return token
            }
        }
        throw MVOrderedSettingsError.malformed
    }

    /// Consumes and returns the raw text of one JSON value — a quoted string verbatim, a balanced
    /// `{...}`/`[...]` span (string literals inside it are skipped over rather than inspected, so
    /// a brace or bracket character inside one never throws off the depth count), or everything up
    /// to the next structural delimiter for a number, `true`, `false` or `null`.
    private static func readValueText(_ chars: inout Substring) throws -> String {
        guard let first = chars.first else { throw MVOrderedSettingsError.malformed }
        if first == "\"" {
            return try readQuotedToken(&chars)
        }
        if first == "{" || first == "[" {
            let open = first
            let close: Character = first == "{" ? "}" : "]"
            var depth = 0
            var consumed = ""
            var inString = false
            var escaped = false
            while let c = chars.first {
                consumed.append(c)
                chars.removeFirst()
                if inString {
                    if escaped {
                        escaped = false
                    } else if c == "\\" {
                        escaped = true
                    } else if c == "\"" {
                        inString = false
                    }
                    continue
                }
                if c == "\"" {
                    inString = true
                } else if c == open {
                    depth += 1
                } else if c == close {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            guard depth == 0 else { throw MVOrderedSettingsError.malformed }
            return consumed
        }
        var consumed = ""
        while let c = chars.first, !",}] \t\n\r".contains(c) {
            consumed.append(c)
            chars.removeFirst()
        }
        guard !consumed.isEmpty else { throw MVOrderedSettingsError.malformed }
        return consumed
    }

    // MARK: - Classification

    private static func classify(_ rawValue: String) throws -> MVSettingsField.Kind {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "true" { return .bool(true) }
        if trimmed == "false" { return .bool(false) }
        if trimmed == "null" { return .null }
        if trimmed.hasPrefix("\"") {
            guard let data = "[\(trimmed)]".data(using: .utf8),
                let decoded = try? JSONDecoder().decode([String].self, from: data),
                let value = decoded.first
            else {
                throw MVOrderedSettingsError.malformed
            }
            return .string(value)
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            guard let data = trimmed.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data)
            else {
                throw MVOrderedSettingsError.malformed
            }
            let pretty = try JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return .json(String(decoding: pretty, as: UTF8.self))
        }
        // `Int.init(String)` only ever succeeds on a plain digit run, rejecting both a fraction
        // and an exponent — so trying it first, and falling back to `Double` when it fails, is
        // already exactly "does the literal carry a fraction", with no separate check needed.
        // `JSONSerialization`'s own `NSNumber` cannot make this distinction at all, which is why
        // this classifies the literal text itself rather than decoding it generically.
        if let value = Int(trimmed) { return .int(value) }
        if let value = Double(trimmed) { return .float(value) }
        throw MVOrderedSettingsError.malformed
    }

    // MARK: - Encoding one field back for a PUT body

    /// `{"data":{"<key>":<value>}}` — the body `PUT /settings/{category}` expects for a merge of
    /// exactly one field, built from text rather than a generic `Encodable` so an int, a float
    /// that happens to be whole, and an already-valid JSON blob each round-trip exactly as typed
    /// rather than through a re-encoding that could normalize one of them into the other.
    public static func singleFieldBody(key: String, kind: MVSettingsField.Kind) throws -> Data {
        let keyText = try jsonStringLiteral(key)
        let valueText = try encode(kind)
        return Data("{\"data\":{\(keyText):\(valueText)}}".utf8)
    }

    private static func encode(_ kind: MVSettingsField.Kind) throws -> String {
        switch kind {
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .float(let value): return String(value)
        case .string(let value): return try jsonStringLiteral(value)
        case .json(let raw): return raw
        case .null: return "null"
        }
    }

    private static func jsonStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode([value])
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("["), text.hasSuffix("]") else { throw MVOrderedSettingsError.malformed }
        return String(text.dropFirst().dropLast())
    }
}
