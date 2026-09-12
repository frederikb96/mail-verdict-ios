import SwiftSoup
import XCTest

/// Proves the dependency itself — parses on this Linux toolchain, not just on a Mac — rather than
/// anything about how the reader will eventually use it; the document builder, sanitizer
/// allowlist and canvas rewriting are the reader's own work, built on top of this dependency.
final class SwiftSoupSmokeTests: XCTestCase {

    func testParsesAndQueriesHTML() throws {
        let doc = try SwiftSoup.parse("<html><body><p class=\"a\">hello</p></body></html>")
        let paragraph = try doc.select("p.a").first()
        XCTAssertEqual(try paragraph?.text(), "hello")
    }

    func testCleanStripsScriptTags() throws {
        let dirty = "<p>safe</p><script>alert(1)</script>"
        let cleaned = try SwiftSoup.clean(dirty, Whitelist.basic())
        XCTAssertFalse(cleaned?.contains("script") ?? true)
        XCTAssertTrue(cleaned?.contains("safe") ?? false)
    }
}
