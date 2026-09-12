#if DEBUG

    import XCTest
    @testable import MailVerdictKit

    final class MVFixtureLaunchTests: XCTestCase {

        func testEnabledOnlyWhenTheFlagIsPresent() {
            XCTAssertTrue(MVFixtureLaunch.isEnabled(arguments: ["/path/to/binary", "-MVFixtureMode"]))
            XCTAssertFalse(MVFixtureLaunch.isEnabled(arguments: ["/path/to/binary"]))
        }

        func testEnabledWithTheTrailingYesXcodeConventionallyAppends() {
            XCTAssertTrue(
                MVFixtureLaunch.isEnabled(arguments: ["/path/to/binary", "-MVFixtureMode", "YES"])
            )
        }

        func testTargetScreenIdReadsTheValueAfterTheFlag() {
            XCTAssertEqual(
                MVFixtureLaunch.targetScreenId(
                    arguments: ["/path/to/binary", "-MVFixtureMode", "-MVFixtureScreen", "mailboxes-fixture-row"]
                ),
                "mailboxes-fixture-row"
            )
        }

        func testTargetScreenIdIsNilWhenTheFlagIsAbsent() {
            XCTAssertNil(MVFixtureLaunch.targetScreenId(arguments: ["/path/to/binary", "-MVFixtureMode"]))
        }

        func testTargetScreenIdIsNilWhenTheFlagHasNoValueFollowingIt() {
            XCTAssertNil(MVFixtureLaunch.targetScreenId(arguments: ["/path/to/binary", "-MVFixtureScreen"]))
        }
    }

#endif
