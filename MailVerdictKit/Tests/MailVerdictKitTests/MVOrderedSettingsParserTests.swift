import XCTest
@testable import MailVerdictKit

final class MVOrderedSettingsParserTests: XCTestCase {

    func testPreservesKeyOrderEvenWhenItDisagreesWithJSONTextOrder() async throws {
        // A `Dictionary`-based decode would report these three keys in an arbitrary order; the
        // parser must report exactly the order they were written in, reversed from how a
        // conventional renderer might guess.
        let data = Data(#"{"zeta": 1, "alpha": 2, "mid": 3}"#.utf8)
        let parsed = try MVOrderedSettingsParser.parse(data)
        XCTAssertEqual(parsed.map(\.key), ["zeta", "alpha", "mid"])
    }

    func testDistinguishesAWholeNumberFloatFromAnInt() async throws {
        let data = Data(#"{"count": 3, "ratio": 3.0, "small": 0.85}"#.utf8)
        let parsed = try MVOrderedSettingsParser.parse(data)
        let kinds = Dictionary(uniqueKeysWithValues: parsed)
        XCTAssertEqual(kinds["count"], .int(3))
        XCTAssertEqual(kinds["ratio"], .float(3.0))
        XCTAssertEqual(kinds["small"], .float(0.85))
    }

    func testExponentNotationIsAFloat() async throws {
        let data = Data(#"{"value": 1e2}"#.utf8)
        let parsed = try MVOrderedSettingsParser.parse(data)
        XCTAssertEqual(parsed.first?.kind, .float(100))
    }

    func testStringsBoolsAndNullRoundTrip() async throws {
        let data = Data(#"{"name": "anthropic", "enabled": true, "off": false, "gone": null}"#.utf8)
        let parsed = try MVOrderedSettingsParser.parse(data)
        let kinds = Dictionary(uniqueKeysWithValues: parsed)
        XCTAssertEqual(kinds["name"], .string("anthropic"))
        XCTAssertEqual(kinds["enabled"], .bool(true))
        XCTAssertEqual(kinds["off"], .bool(false))
        XCTAssertEqual(kinds["gone"], .null)
    }

    /// A string containing a brace or a comma must never be mistaken for structure — the kind of
    /// bug a naive "scan for the next delimiter" reader would have.
    func testAStringValueContainingStructuralCharactersDoesNotConfuseTheScanner() async throws {
        let data = Data(#"{"model": "a, {weird} value", "next": 5}"#.utf8)
        let parsed = try MVOrderedSettingsParser.parse(data)
        let kinds = Dictionary(uniqueKeysWithValues: parsed)
        XCTAssertEqual(kinds["model"], .string("a, {weird} value"))
        XCTAssertEqual(kinds["next"], .int(5))
    }

    func testNestedObjectAndArrayValuesAreCapturedAsPrettyPrintedJSONRatherThanParsedFields() async throws {
        let data = Data(#"{"config": {"b": 1, "a": 2}, "tags": [1, 2, 3]}"#.utf8)
        let parsed = try MVOrderedSettingsParser.parse(data)
        let kinds = Dictionary(uniqueKeysWithValues: parsed)
        guard case .json(let configText) = kinds["config"] else {
            return XCTFail("expected config to parse as a json blob")
        }
        // Re-parsing the captured text must still be the same object — this only asserts the
        // text is valid, re-serializable JSON, not a specific pretty-printed layout.
        let reparsed = try JSONSerialization.jsonObject(with: Data(configText.utf8)) as? [String: Any]
        XCTAssertEqual(reparsed?["a"] as? Int, 2)
        XCTAssertEqual(reparsed?["b"] as? Int, 1)
        guard case .json(let tagsText) = kinds["tags"] else {
            return XCTFail("expected tags to parse as a json blob")
        }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(tagsText.utf8)) as? [Int], [1, 2, 3])
    }

    func testRejectsATopLevelArray() async throws {
        XCTAssertThrowsError(try MVOrderedSettingsParser.parse(Data("[1, 2]".utf8)))
    }

    // MARK: - Building a single-field PUT body

    func testSingleFieldBodyWrapsAnIntFieldUnquoted() async throws {
        let body = try MVOrderedSettingsParser.singleFieldBody(key: "max_attempts", kind: .int(5))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let data = try XCTUnwrap(object?["data"] as? [String: Any])
        XCTAssertEqual(data["max_attempts"] as? Int, 5)
        XCTAssertEqual(Set(data.keys), ["max_attempts"])
    }

    func testSingleFieldBodyEscapesAStringValue() async throws {
        let body = try MVOrderedSettingsParser.singleFieldBody(
            key: "model", kind: .string("a \"quoted\" value"))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let data = try XCTUnwrap(object?["data"] as? [String: Any])
        XCTAssertEqual(data["model"] as? String, "a \"quoted\" value")
    }

    func testSingleFieldBodyCarriesAnAlreadyValidatedJSONBlobVerbatim() async throws {
        let body = try MVOrderedSettingsParser.singleFieldBody(
            key: "config", kind: .json(#"{"a":1}"#))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let data = try XCTUnwrap(object?["data"] as? [String: Any])
        XCTAssertEqual((data["config"] as? [String: Any])?["a"] as? Int, 1)
    }
}
