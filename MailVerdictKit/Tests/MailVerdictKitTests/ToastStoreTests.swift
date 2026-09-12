import XCTest
@testable import MailVerdictKit

@MainActor
final class ToastStoreTests: XCTestCase {

    func testShowingAToastSetsCurrent() {
        let store = MVToastStore()
        store.show(MVToast(variant: .info, message: "Hi", duration: 0))
        XCTAssertEqual(store.current?.message, "Hi")
    }

    func testADurationOfZeroIsPersistentUntilDismissed() async throws {
        let store = MVToastStore()
        let toast = MVToast(variant: .info, message: "Persistent", duration: 0)
        store.show(toast)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(store.current)
        store.dismiss(id: toast.id)
        XCTAssertNil(store.current)
    }

    func testANewerToastReplacesTheCurrentOne() {
        let store = MVToastStore()
        store.show(MVToast(variant: .info, message: "First", duration: 0))
        store.show(MVToast(variant: .error, message: "Second", duration: 0))
        XCTAssertEqual(store.current?.message, "Second")
    }

    /// A delayed auto-dismiss firing for a toast that was already replaced must never dismiss
    /// the one that replaced it.
    func testDismissingByIdIgnoresAStaleToast() {
        let store = MVToastStore()
        let first = MVToast(variant: .info, message: "First", duration: 0)
        store.show(first)
        store.show(MVToast(variant: .info, message: "Second", duration: 0))
        store.dismiss(id: first.id)
        XCTAssertEqual(store.current?.message, "Second")
    }

    func testAutoDismissesAfterItsDuration() async throws {
        let store = MVToastStore()
        store.show(MVToast(variant: .success, message: "Brief", duration: 0.05))
        XCTAssertNotNil(store.current)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(store.current)
    }
}

final class SymbolsTests: XCTestCase {
    func testFolderIconBySpecialUse() {
        XCTAssertEqual(MVSymbols.folderIcon(specialUse: "inbox"), "tray")
        XCTAssertEqual(MVSymbols.folderIcon(specialUse: "trash"), "trash")
        XCTAssertEqual(MVSymbols.folderIcon(specialUse: nil), "folder")
        XCTAssertEqual(MVSymbols.folderIcon(specialUse: "something-else"), "folder")
    }
}
