#if DEBUG

    import XCTest
    @testable import MailVerdictKit

    final class MVFixtureLaunchTests: XCTestCase {

        func testEnabledOnlyWhenTheFlagIsPresent() {
            XCTAssertTrue(MVFixtureLaunch.isEnabled(arguments: ["/path/to/binary", "-MVFixtureMode"]))
            XCTAssertFalse(MVFixtureLaunch.isEnabled(arguments: ["/path/to/binary"]))
        }
    }

#endif
