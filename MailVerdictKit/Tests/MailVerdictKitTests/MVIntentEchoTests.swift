import XCTest

@testable import MailVerdictKit

/// Telling the event stream's echo of an answered action from another client's change: an event
/// that arrived after the request left and no later than the grace after its answer.
@MainActor
final class MVIntentEchoTests: XCTestCase {

    private func settledArchive(clock: TestIntentClock) async -> MVIntentLedger {
        let ledger = makeTestLedger(transport: RecordingIntentTransport(), clock: clock)
        ledger.enqueue(
            MVIntentRequest(
                accountId: testAccount, action: .archive, messageIds: [testUUID(1)],
                originFolderIds: [testUUID(1): testFolder], snapshots: [testRow(1)]))
        await waitUntil { ledger.intents.first?.state == .done }
        return ledger
    }

    func testAnEventFromTheRequestsWindowThroughTheGraceIsItsEcho() async {
        let clock = TestIntentClock()
        let ledger = await settledArchive(clock: clock)
        let answered = clock.now

        func echo(_ offset: TimeInterval, _ id: Int = 1, account: UUID = testAccount) -> Bool {
            ledger.isSettledEcho(of: testUUID(id), accountId: account, arrivedAt: answered.addingTimeInterval(offset))
        }
        XCTAssertTrue(echo(0))
        XCTAssertTrue(echo(MVIntentLedger.Timing().echoGrace))
        XCTAssertFalse(echo(MVIntentLedger.Timing().echoGrace + 0.1), "an event well after the answer is not its echo")
        XCTAssertFalse(echo(-1), "an event from before the request left cannot be its echo")
        XCTAssertFalse(echo(0, 2), "another message's change is not")
        XCTAssertFalse(echo(0, account: testUUID(77)), "nor is another account's")
    }

    func testARequestStillOutHasNoEchoYet() async {
        let gate = TestGate()
        let transport = RecordingIntentTransport()
        transport.handler = { _ in await gate.wait() }
        let clock = TestIntentClock()
        let ledger = makeTestLedger(transport: transport, clock: clock)
        ledger.enqueue(
            MVIntentRequest(accountId: testAccount, action: .archive, messageIds: [testUUID(1)]))
        await waitUntil { transport.calls.count == 1 }

        XCTAssertFalse(ledger.isSettledEcho(of: testUUID(1), accountId: testAccount, arrivedAt: clock.now))
        await gate.open()
    }

    func testAnIntentWrittenBeforeSendTimesWereRecordedDecodes() throws {
        let intent = MVMailIntent(
            request: MVIntentRequest(accountId: testAccount, action: .archive, messageIds: [testUUID(1)]),
            id: UUID(), undoes: nil, createdAt: Date())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.mvDefault.encode(intent)) as? [String: Any])
        object.removeValue(forKey: "sentAt")
        let decoded = try JSONDecoder.mvDefault.decode(
            MVMailIntent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.sentAt)
    }
}
