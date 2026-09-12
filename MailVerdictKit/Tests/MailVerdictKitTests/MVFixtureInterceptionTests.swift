#if DEBUG

    import XCTest
    @testable import MailVerdictKit

    // URLSession and friends live in FoundationNetworking on Linux, where the free CI runner
    // builds this package. On Apple platforms the module does not exist and Foundation already
    // has them.
    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    /// `MVFixtureURLProtocolTests` proves the route table itself; this proves the other half —
    /// that a real `URLSession`-backed client actually gets routed through it once fixture mode
    /// is on, which is what a Mac sweep screen depends on and what regressed when
    /// `URLProtocol.registerClass` turned out not to reach a session built with its own delegate.
    final class MVFixtureInterceptionTests: XCTestCase {

        override func tearDown() {
            MVFixtureURLProtocol.resetToDefaults()
            super.tearDown()
        }

        func testInstallIfEnabledPrependsItselfWithoutDroppingExistingClasses() {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MVStubURLProtocol.self]

            MVFixtureURLProtocol.installIfEnabled(in: configuration, enabled: true)

            XCTAssertTrue(configuration.protocolClasses?.first == MVFixtureURLProtocol.self)
            XCTAssertTrue(configuration.protocolClasses?.contains(where: { $0 == MVStubURLProtocol.self }) == true)
        }

        func testInstallIfEnabledIsANoOpWhenDisabled() {
            let configuration = URLSessionConfiguration.ephemeral
            let before = configuration.protocolClasses.map { $0.map(ObjectIdentifier.init) }
            MVFixtureURLProtocol.installIfEnabled(in: configuration, enabled: false)
            let after = configuration.protocolClasses.map { $0.map(ObjectIdentifier.init) }
            XCTAssertEqual(before, after)
        }

        /// The proof `MVApiClient.getHealth()` in fixture mode is answered by the table, not the
        /// network — the base URL (`fixture.invalid`) cannot resolve at all, so a body this
        /// specific can only have come from the registered fixture, never a real response.
        func testMVApiClientInFixtureModeIsAnsweredByTheFixtureTable() async throws {
            MVFixtureURLProtocol.register(method: "GET", path: "/api/health", status: 200) {
                Data(#"{"status":"not_ready","postimap_contract":"fixture","database":"fixture-only"}"#.utf8)
            }

            let configuration = URLSessionConfiguration.ephemeral
            MVFixtureURLProtocol.installIfEnabled(in: configuration, enabled: true)
            let session = URLSession(configuration: configuration)
            let factory = try MVRequestFactory(baseURL: "https://fixture.invalid", authProvider: { .none })
            let client = MVApiClient(requestFactory: factory, urlSession: session)

            let health = try await client.getHealth()
            XCTAssertEqual(health.database, "fixture-only")
        }

        /// A request fixture mode has no route for is still answered (404, never a hung or
        /// crashing call), and is recorded so a screen that silently fell back to an error state
        /// shows up on `/fixtures/misses` instead of passing its screenshot by accident.
        func testAnUnmatchedRequestInFixtureModeIsRecordedAsAMiss() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            MVFixtureURLProtocol.installIfEnabled(in: configuration, enabled: true)
            let session = URLSession(configuration: configuration)
            let factory = try MVRequestFactory(baseURL: "https://fixture.invalid", authProvider: { .none })
            let client = MVApiClient(requestFactory: factory, urlSession: session)

            do {
                _ = try await client.searchContacts(query: "anything")
                XCTFail("expected the unregistered route to throw")
            } catch {
                // Expected — /api/contacts/search has no fixture registered above.
            }

            XCTAssertTrue(MVFixtureURLProtocol.misses.contains("GET /api/contacts/search"))
        }
    }

#endif
