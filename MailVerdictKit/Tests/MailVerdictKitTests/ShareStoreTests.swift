import XCTest

@testable import MailVerdictKit

/// Scripted server for the share sheet: records what reached it and fails on demand.
private final class StubShareBackend: ShareBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _accounts: [AccountResponse] = []
    private var _orderErrors: [String: MVError] = [:]
    private var _draftError: MVError?
    private var _orderUploads: [String] = []
    private var _drafts: [(request: OutboxCreateRequest, uploads: [MVOutboxAttachmentUpload])] = []
    private var _draftKeys: [UUID?] = []

    var orderUploads: [String] { lock.withLock { _orderUploads } }
    /// The idempotency key of every attempt, failed ones included.
    var draftKeys: [UUID?] { lock.withLock { _draftKeys } }
    var drafts: [(request: OutboxCreateRequest, uploads: [MVOutboxAttachmentUpload])] { lock.withLock { _drafts } }

    func set(accounts: [AccountResponse]) { lock.withLock { _accounts = accounts } }
    func failOrder(_ filename: String, with error: MVError?) { lock.withLock { _orderErrors[filename] = error } }
    func set(draftError: MVError?) { lock.withLock { _draftError = draftError } }

    func accountsToShareInto() async throws -> [AccountResponse] { lock.withLock { _accounts } }

    func addToOrders(_ file: ShareFile) async throws {
        try lock.withLock {
            if let error = _orderErrors[file.filename] { throw error }
            _orderUploads.append(file.filename)
        }
    }

    func saveDraft(_ request: OutboxCreateRequest, uploads: [MVOutboxAttachmentUpload]) async throws {
        try lock.withLock {
            _draftKeys.append(request.idempotencyKey)
            if let error = _draftError { throw error }
            _drafts.append((request, uploads))
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    private var _history: [Bool] = []
    var value: Bool { lock.withLock { _value } }
    var history: [Bool] { lock.withLock { _history } }
    func set(_ value: Bool) {
        lock.withLock {
            _value = value
            _history.append(value)
        }
    }
}

@MainActor
final class ShareStoreTests: XCTestCase {

    private func file(_ name: String, size: Int = 10, type: String = "application/pdf") -> ShareItem {
        ShareItem(name: name, sizeBytes: size) { _ in
            ShareFile(filename: name, contentType: type, data: Data(count: size))
        }
    }

    private func store(
        _ items: [ShareItem], backend: StubShareBackend, mark: Flag = Flag(),
        lastAccount: UUID? = nil, remember: @escaping @Sendable (UUID) -> Void = { _ in }
    ) -> ShareStore {
        ShareStore(
            items: items, refusal: nil, backend: backend,
            attemptMark: ShareAttemptMark(isSet: { mark.value }, set: { mark.set($0) }),
            accountMemory: ShareAccountMemory(read: { lastAccount }, write: remember))
    }

    private func account(_ name: String, id: UUID = UUID(), active: Bool = true) -> AccountResponse {
        var account = ComposeFixtureFactory.account(id: id, imapUser: "\(name)@test", name: name)
        account.isActive = active
        return account
    }

    // MARK: - Orders

    func testEveryFileGoesToOrdersOnceAndARetryResendsOnlyTheMissing() async {
        let backend = StubShareBackend()
        backend.failOrder("b.pdf", with: .transport("offline"))
        let store = store([file("a.pdf"), file("b.pdf"), file("c.pdf")], backend: backend)

        await store.send(to: .orders)
        XCTAssertEqual(store.phase, .failed(.orders, message: "offline"))
        XCTAssertEqual(backend.orderUploads, ["a.pdf"])

        backend.failOrder("b.pdf", with: nil)
        await store.send(to: .orders)
        XCTAssertEqual(store.phase, .sent(.orders))
        XCTAssertEqual(backend.orderUploads, ["a.pdf", "b.pdf", "c.pdf"])
    }

    func testAFileTheServerRefusesDoesNotStopTheOthers() async {
        let backend = StubShareBackend()
        backend.failOrder("a.pdf", with: .http(statusCode: 413, reason: "Payload Too Large"))
        let store = store([file("a.pdf"), file("b.pdf")], backend: backend)

        await store.send(to: .orders)

        XCTAssertEqual(backend.orderUploads, ["b.pdf"])
        XCTAssertEqual(store.phase, .failed(.orders, message: "a.pdf: This file is larger than the server takes."))
    }

    func testARefusedCredentialStopsTheRunAndSaysToSignIn() async {
        let backend = StubShareBackend()
        backend.failOrder("a.pdf", with: .detail("Not authenticated", statusCode: 401))
        let store = store([file("a.pdf"), file("b.pdf")], backend: backend)

        await store.send(to: .orders)

        XCTAssertEqual(backend.orderUploads, [])
        guard case .failed(_, let message) = store.phase else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("Open the app, sign in"), message)
    }

    func testAFileOverTheLimitIsReportedAndTheRestStillGo() async {
        let backend = StubShareBackend()
        let big = ShareItem(name: "big.pdf", sizeBytes: 10) { _ in
            ShareFile(
                filename: "big.pdf", contentType: "application/pdf", data: Data(count: ShareLimits.maxFileBytes + 1))
        }
        let store = store([big, file("b.pdf")], backend: backend)

        await store.send(to: .orders)

        XCTAssertEqual(backend.orderUploads, ["b.pdf"])
        XCTAssertEqual(store.phase, .failed(.orders, message: "big.pdf: This file is larger than the server takes."))
    }

    // MARK: - Drafts

    func testADraftCarriesEveryFileInOneRequestWithNoRecipient() async throws {
        let backend = StubShareBackend()
        let accountId = UUID()
        let remembered = Flag()
        let store = store(
            [file("a.pdf", size: 5), file("b.png", size: 7, type: "image/png")], backend: backend,
            remember: { _ in remembered.set(true) })
        let destination = ShareDestination.draft(accountId: accountId, accountName: "Home")

        await store.send(to: destination)

        XCTAssertEqual(store.phase, .sent(destination))
        let draft = try XCTUnwrap(backend.drafts.first)
        XCTAssertEqual(backend.drafts.count, 1)
        XCTAssertEqual(draft.request.kind, .draft)
        XCTAssertEqual(draft.request.accountId, accountId)
        XCTAssertEqual(draft.request.to, [])
        XCTAssertEqual(draft.request.subject, "a.pdf and 1 more")
        XCTAssertNotNil(draft.request.idempotencyKey)
        XCTAssertEqual(draft.uploads.map(\.filename), ["a.pdf", "b.png"])
        XCTAssertEqual(draft.uploads.map(\.data.count), [5, 7])
        XCTAssertTrue(remembered.value)
    }

    func testARetriedDraftReusesItsKeySoALostAnswerIsTheSameRow() async throws {
        let backend = StubShareBackend()
        backend.set(draftError: .transport("offline"))
        let store = store([file("a.pdf")], backend: backend)
        let destination = ShareDestination.draft(accountId: UUID(), accountName: "Home")

        await store.send(to: destination)
        XCTAssertEqual(store.phase, .failed(destination, message: "offline"))

        backend.set(draftError: nil)
        await store.send(to: destination)
        await store.send(to: destination)  // already sent: a second tap does nothing

        XCTAssertEqual(backend.drafts.count, 1)
        XCTAssertEqual(backend.draftKeys.count, 2)
        XCTAssertNotNil(backend.draftKeys[0])
        XCTAssertEqual(backend.draftKeys[0], backend.draftKeys[1])

        let another = self.store([file("a.pdf")], backend: backend)
        await another.send(to: destination)
        XCTAssertNotEqual(backend.draftKeys.last, backend.draftKeys[0], "a new share gets its own key")
    }

    func testADraftTooLargeForTheExtensionIsRefusedBeforeAnyUpload() async {
        let backend = StubShareBackend()
        let store = store(
            [file("a.pdf", size: ShareLimits.maxDraftBytes), file("b.pdf", size: 1)], backend: backend)
        let destination = ShareDestination.draft(accountId: UUID(), accountName: "Home")

        XCTAssertNotNil(store.draftRefusal)
        await store.send(to: destination)

        XCTAssertEqual(backend.drafts.count, 0)
        guard case .failed(_, let message) = store.phase else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("Attach them in MailVerdict"), message)
    }

    func testTooManyFilesForADraftAreRefused() {
        let items = (0...ShareLimits.maxDraftFiles).map { file("f\($0).txt", size: 1) }
        XCTAssertNotNil(store(items, backend: StubShareBackend()).draftRefusal)
        XCTAssertNil(store(Array(items.dropLast()), backend: StubShareBackend()).draftRefusal)
    }

    func testDraftSubjectNamesTheFileOrCountsTheRest() {
        XCTAssertEqual(ShareStore.draftSubject(["x.pdf"]), "x.pdf")
        XCTAssertEqual(ShareStore.draftSubject(["x.pdf", "y.pdf", "z.pdf"]), "x.pdf and 2 more")
        XCTAssertNil(ShareStore.draftSubject([]))
    }

    // MARK: - Accounts and the attempt mark

    func testOnlyActiveAccountsAreOfferedAndTheLastUsedComesFirst() async {
        let backend = StubShareBackend()
        let last = UUID()
        backend.set(accounts: [account("one"), account("off", active: false), account("two", id: last)])
        let store = store([file("a.pdf")], backend: backend, lastAccount: last)

        await store.loadAccounts()

        XCTAssertEqual(store.accounts.map(\.name), ["two", "one"])
        XCTAssertTrue(store.accountsLoaded)
    }

    func testTheAttemptMarkIsSetWhileSendingAndClearedAfter() async {
        let backend = StubShareBackend()
        let mark = Flag()
        let store = store([file("a.pdf")], backend: backend, mark: mark)

        await store.send(to: .orders)

        XCTAssertEqual(mark.history, [false, true, false])
    }

    func testAMarkLeftBehindIsReportedOnTheNextShare() {
        let mark = Flag()
        mark.set(true)
        let store = store([file("a.pdf")], backend: StubShareBackend(), mark: mark)

        XCTAssertTrue(store.previousAttemptDied)
        XCTAssertFalse(mark.value)
    }

    // MARK: - Image plan

    func testOrdersTakesJPEGAndPNGAsTheyAreUnlessLarge() {
        for type in ["image/jpeg", "image/png"] {
            XCTAssertNil(
                ShareImagePlan.plan(contentType: type, filename: "a", longestEdge: 2_000, policy: .orders))
        }
        XCTAssertEqual(
            ShareImagePlan.plan(contentType: "image/png", filename: "a.png", longestEdge: 4_000, policy: .orders)?
                .maxLongEdge, ShareLimits.ordersImageLongEdge)
    }

    func testOrdersConvertsHEICWithoutScalingASmallOne() {
        let plan = ShareImagePlan.plan(
            contentType: "image/heic", filename: "IMG.HEIC", longestEdge: 1_200, policy: .orders)
        XCTAssertEqual(plan, ShareImagePlan.Plan(maxLongEdge: nil))
    }

    func testADraftKeepsImagesAsTheyAreExceptHEIC() {
        XCTAssertNil(
            ShareImagePlan.plan(contentType: "image/png", filename: "a.png", longestEdge: 9_000, policy: .draft))
        XCTAssertEqual(
            ShareImagePlan.plan(contentType: "image/heic", filename: "a.heic", longestEdge: 9_000, policy: .draft),
            ShareImagePlan.Plan(maxLongEdge: nil))
    }

    func testAFileThatIsNotAnImageNeedsNoPlan() {
        XCTAssertNil(
            ShareImagePlan.plan(contentType: "application/pdf", filename: "a.pdf", longestEdge: 9_000, policy: .orders))
    }
}
