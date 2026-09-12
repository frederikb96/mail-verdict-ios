/// Conformed to by every model that mirrors one of the backend's named OpenAPI component
/// schemas — `ContractTests` (Linux, free) asserts each one against the vendored snapshot at
/// `Tests/MailVerdictKitTests/Fixtures/api-contract/openapi.json`:
///
/// - `schemaName` exists in `components.schemas`
/// - every `ContractKeys.stringValue` is a property of that schema (a field Swift reads that the
///   backend never sends is the silent bug this catches)
/// - a minimal instance built from the schema itself (required properties only, nullable ones
///   `null`) decodes without throwing (Swift non-optional where the backend is nullable or
///   omitted is the crash-direction bug this catches)
///
/// A model with no named component schema of its own (the backend inlines it, or it is this
/// app's own shape, like `HealthResponse`) does not conform — there is nothing in the snapshot to
/// check it against.
public protocol ContractModel: Decodable {
    /// The exact name under `components.schemas` in the vendored OpenAPI snapshot.
    static var schemaName: String { get }
    associatedtype ContractKeys: CodingKey & CaseIterable
}
