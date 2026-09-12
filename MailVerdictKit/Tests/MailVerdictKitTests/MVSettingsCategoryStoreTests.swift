import XCTest
@testable import MailVerdictKit

@MainActor
final class MVSettingsCategoryStoreTests: XCTestCase {

    private func makeStore(category: MVSettingsCategory = .retry) throws -> MVSettingsCategoryStore {
        let factory = try MVRequestFactory(baseURL: "https://example.com", authProvider: { .none })
        return MVSettingsCategoryStore(category: category, apiClient: MVApiClient(requestFactory: factory))
    }

    func testFieldsAreOrderedByLabelOrderThenAlphabetically() async throws {
        // "max_attempts" and "base_delay_seconds" are both labelled, in that declaration order;
        // "zzz_unlabelled" and "aaa_unlabelled" are not, so they follow, alphabetically.
        let data = Data(
            #"{"zzz_unlabelled": 1, "max_attempts": 2, "aaa_unlabelled": 3, "base_delay_seconds": 4}"#
                .utf8)
        let store = try makeStore()
        try store.apply(data)
        XCTAssertEqual(
            store.fields.map(\.key),
            ["base_delay_seconds", "max_attempts", "aaa_unlabelled", "zzz_unlabelled"])
    }

    func testIdAndCategoryAreNeverShownAsFields() async throws {
        let data = Data(#"{"id": "x", "category": "retry", "max_attempts": 5}"#.utf8)
        let store = try makeStore()
        try store.apply(data)
        XCTAssertEqual(store.fields.map(\.key), ["max_attempts"])
    }

    /// The `ai` category's credential-status fields must never reach the generic field list —
    /// `ProviderKeySettings`'s own dedicated form reads them, not a `TextField`.
    func testAiCategoryExcludesProviderKeyStatusFieldsFromTheGenericList() async throws {
        let data = Data(
            #"""
            {"anthropic_api_key_configured": true, "anthropic_api_key_hint": "abcd",
             "openai_api_key_configured": false, "openai_api_key_hint": null, "model": "haiku"}
            """#.utf8)
        let store = try makeStore(category: .ai)
        try store.apply(data)
        XCTAssertEqual(store.fields.map(\.key), ["model"])
        XCTAssertEqual(store.providerStatus[.anthropic], MVProviderKeyStatus(configured: true, hint: "abcd"))
        XCTAssertEqual(store.providerStatus[.openai], MVProviderKeyStatus(configured: false, hint: nil))
    }

    /// Only the `ai` category carries provider keys — a category switch must not leave a stale
    /// status behind from whatever was loaded before it.
    func testNonAiCategoriesHaveNoProviderStatus() async throws {
        let data = Data(#"{"max_attempts": 5}"#.utf8)
        let store = try makeStore(category: .retry)
        try store.apply(data)
        XCTAssertTrue(store.providerStatus.isEmpty)
    }
}
