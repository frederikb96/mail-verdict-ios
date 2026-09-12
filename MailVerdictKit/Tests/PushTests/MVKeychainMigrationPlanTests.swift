import XCTest

@testable import PushEnvelope

/// The decision logic behind `PushKeychain.migrateFromLegacyGroupIfNeeded()`, with no `Security`
/// calls at all — whether a given origin needs copying out of the legacy access group.
final class MVKeychainMigrationPlanTests: XCTestCase {

    func testAnOriginOnlyInTheLegacyGroupIsMigrated() {
        let steps = MVKeychainMigrationPlan.steps(
            legacyOrigins: ["https://mail.example.com"], currentOrigins: [])
        XCTAssertEqual(steps, [MVKeychainMigrationStep(serverOrigin: "https://mail.example.com")])
    }

    func testAnOriginAlreadyPresentInTheNewGroupIsLeftAlone() {
        // A second launch after a partial migration: this origin already made it across, so
        // re-copying it would stomp on whatever the app wrote there since.
        let steps = MVKeychainMigrationPlan.steps(
            legacyOrigins: ["https://mail.example.com"], currentOrigins: ["https://mail.example.com"])
        XCTAssertEqual(steps, [])
    }

    func testOnlyTheStillOutstandingOriginsAreMigrated() {
        let steps = MVKeychainMigrationPlan.steps(
            legacyOrigins: ["https://a.example.com", "https://b.example.com", "https://c.example.com"],
            currentOrigins: ["https://b.example.com"])
        XCTAssertEqual(
            Set(steps.map(\.serverOrigin)), ["https://a.example.com", "https://c.example.com"])
    }

    func testNoLegacyInstallationsMeansNothingToDo() {
        XCTAssertEqual(MVKeychainMigrationPlan.steps(legacyOrigins: [], currentOrigins: []), [])
    }
}
