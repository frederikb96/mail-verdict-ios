import Foundation
import MailVerdictKit
import XCTest

@testable import Push

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A transport failure never becomes an `MVError`, and printed as-is it is an `NSError` dump no
/// one can act on.
@MainActor
final class PushErrorTextTests: XCTestCase {

    func testAnUnreachableServerIsDescribedInAShortLine() async {
        let backend = FakePushBackend()
        backend.configError = URLError(.notConnectedToInternet)
        let store = NotificationSettingsStore(
            dependencies: .init(
                backend: backend,
                records: PushRecordStore(defaults: UserDefaults(suiteName: "push-errors-\(UUID().uuidString)")!),
                serverOrigin: "https://mail.example", authorization: { .authorized },
                requestAuthorization: { true }, beginRegistration: {}, unregister: { _ in }))

        await store.reload()

        XCTAssertEqual(store.status, .loadFailed("No internet connection."))
    }
}
