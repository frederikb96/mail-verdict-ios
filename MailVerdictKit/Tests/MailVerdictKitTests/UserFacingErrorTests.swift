import XCTest
@testable import MailVerdictKit

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class UserFacingErrorTests: XCTestCase {

    func testAnMVErrorDetailShowsTheServersOwnText() {
        let error = MVError.detail("That backup codes is wrong.", statusCode: 400)
        XCTAssertEqual(error.mvUserMessage, "That backup codes is wrong.")
    }

    func testProxyRequiresBrowserLoginExplainsWhatHappened() {
        XCTAssertTrue(MVError.proxyRequiresBrowserLogin.mvUserMessage.contains("browser sign-in"))
    }

    func testOfflineReadsAsNoInternetConnection() {
        XCTAssertEqual(URLError(.notConnectedToInternet).mvUserMessage, "No internet connection.")
    }

    func testHostNotFoundReadsAsUnreachable() {
        XCTAssertEqual(URLError(.cannotFindHost).mvUserMessage, "That address could not be reached.")
    }

    func testTimeoutReadsAsTimedOut() {
        XCTAssertEqual(URLError(.timedOut).mvUserMessage, "The connection timed out.")
    }

    func testUntrustedCertificateMentionsSecurity() {
        XCTAssertTrue(URLError(.serverCertificateUntrusted).mvUserMessage.contains("security"))
    }

    func testCancelledReadsAsCancelled() {
        XCTAssertEqual(URLError(.cancelled).mvUserMessage, "Cancelled.")
    }

    /// Never the raw `Domain=NSURLErrorDomain Code=-1003 ...` dump `String(describing:)` or
    /// `"\(error)"` would produce — every case above proves one family maps to short text, this
    /// proves the escape hatch for a family neither `MVError` nor this test covers is still not
    /// that raw form.
    func testAnUnmappedErrorFallsBackToItsOwnLocalizedDescriptionNeverARawDump() {
        struct OtherError: Error, LocalizedError {
            var errorDescription: String? { "Something specific went wrong." }
        }
        let message = OtherError().mvUserMessage
        XCTAssertEqual(message, "Something specific went wrong.")
        XCTAssertFalse(message.contains("Domain="))
    }

    func testTechnicalDetailCarriesTheOriginalErrorsOwnDescription() {
        let detail = URLError(.cannotFindHost).mvTechnicalDetail
        XCTAssertTrue(detail.contains("NSURLErrorDomain") || detail.contains("cannotFindHost"), detail)
    }
}
