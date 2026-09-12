import XCTest
@testable import MailVerdictKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Checks every `ContractModel` in `ContractRegistry.all` against the vendored OpenAPI snapshot —
/// see `ContractModel`'s own doc comment for exactly what each of the three checks below catches.
/// `Tests/Fixtures/api-contract/` is read straight off disk via `#filePath` rather than declared
/// as a package resource: the fixtures are for Linux-run tests only, never shipped in the app, so
/// there is nothing for a `resources:` entry to bundle into the built product.
final class ContractTests: XCTestCase {

    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/api-contract")

    // Read once at first use and never mutated after — `nonisolated(unsafe)` says exactly that,
    // since `[String: Any]` itself cannot be `Sendable`.
    nonisolated(unsafe) private static let document: [String: Any] = {
        let url = fixturesDirectory.appendingPathComponent("openapi.json")
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            fatalError("could not read or parse \(url.path) — run Tooling/sync-contract.sh")
        }
        return object
    }()

    nonisolated(unsafe) private static let schemas: [String: [String: Any]] = {
        (document["components"] as? [String: Any])?["schemas"] as? [String: [String: Any]] ?? [:]
    }()

    // MARK: - Schema existence and key coverage

    func testEveryRegisteredSchemaNameExistsInTheSnapshot() {
        for type in ContractRegistry.all {
            XCTAssertNotNil(
                Self.schemas[type.schemaName],
                "\(type) names schema \"\(type.schemaName)\", absent from the vendored snapshot"
            )
        }
    }

    func testEveryContractKeyIsASchemaProperty() {
        for type in ContractRegistry.all {
            guard let schema = Self.schemas[type.schemaName] else { continue }  // asserted above
            let properties = (schema["properties"] as? [String: Any]) ?? [:]
            for keyName in type.mvContractKeyNames() {
                XCTAssertNotNil(
                    properties[keyName],
                    "\(type).ContractKeys \"\(keyName)\" is not a property of \(type.schemaName)"
                )
            }
        }
    }

    // MARK: - Minimal-instance decode

    /// Required properties only, nullable ones `null`, `format: uuid`/`date-time` fixed values,
    /// enums their first value, arrays empty, `$ref` recursed — see `ContractModel`'s doc comment.
    /// A non-required property is omitted entirely, the same as a server that never sends it; a
    /// Swift field declared non-optional for one of those is exactly the crash this test exists
    /// to catch before a device does.
    func testMinimalInstanceFromTheSchemaDecodes() throws {
        for type in ContractRegistry.all {
            guard Self.schemas[type.schemaName] != nil else { continue }  // asserted above
            let minimal = Self.minimalInstance(forSchemaName: type.schemaName)
            let data = try JSONSerialization.data(withJSONObject: minimal)
            do {
                _ = try JSONDecoder.mvDefault.decode(type, from: data)
            } catch {
                XCTFail(
                    "\(type) failed to decode its own schema's minimal instance: \(error)\n"
                        + "JSON: \(minimal)"
                )
            }
        }
    }

    private static func minimalInstance(forSchemaName name: String) -> [String: Any] {
        guard let schema = schemas[name] else { return [:] }
        let required = (schema["required"] as? [String]) ?? []
        let properties = (schema["properties"] as? [String: Any]) ?? [:]
        var instance: [String: Any] = [:]
        for key in required {
            guard let propertySchema = properties[key] as? [String: Any] else { continue }
            instance[key] = isNullable(propertySchema) ? NSNull() : minimalValue(for: propertySchema)
        }
        return instance
    }

    private static func isNullable(_ schema: [String: Any]) -> Bool {
        guard let anyOf = schema["anyOf"] as? [[String: Any]] else { return false }
        return anyOf.contains { ($0["type"] as? String) == "null" }
    }

    private static func minimalValue(for schema: [String: Any]) -> Any {
        if let ref = schema["$ref"] as? String, let name = ref.split(separator: "/").last {
            return minimalInstance(forSchemaName: String(name))
        }
        if let anyOf = schema["anyOf"] as? [[String: Any]] {
            let chosen = anyOf.first { ($0["type"] as? String) != "null" } ?? anyOf.first ?? [:]
            return minimalValue(for: chosen)
        }
        if let enumValues = schema["enum"] as? [Any], let first = enumValues.first {
            return first
        }
        switch schema["type"] as? String {
        case "string":
            switch schema["format"] as? String {
            case "uuid": return "00000000-0000-0000-0000-000000000000"
            case "date-time": return "2024-01-01T00:00:00+00:00"
            default: return "x"
            }
        case "integer", "number": return 0
        case "boolean": return false
        case "array": return []
        case "object": return [String: Any]()
        default: return NSNull()
        }
    }

    // MARK: - SSE event names

    /// Both directions: an event `SSEEventName` carries that the backend has stopped sending
    /// would never be noticed otherwise, since an unused enum case fails nothing on its own.
    func testSSEEventNamesMatchTheSnapshotBothDirections() throws {
        let url = Self.fixturesDirectory.appendingPathComponent("sse-events.json")
        let data = try Data(contentsOf: url)
        let snapshotNames = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(
            Set(snapshotNames), Set(SSEEventName.allCases.map(\.rawValue)),
            "SSEEventName has drifted from the vendored sse-events.json snapshot"
        )
    }
}

extension ContractModel {
    /// Non-generic on purpose: called through the `any ContractModel.Type` existentials
    /// `ContractRegistry.all` holds, where a caller can read a concrete `[String]` back across
    /// the existential boundary but cannot open `Self.ContractKeys` generically without it.
    fileprivate static func mvContractKeyNames() -> [String] {
        ContractKeys.allCases.map(\.stringValue)
    }
}
