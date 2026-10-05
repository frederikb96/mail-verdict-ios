import XCTest
@testable import MailVerdictKit

@MainActor
final class RuleAssistantStoreTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore() -> RuleAssistantStore {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        return RuleAssistantStore(messageId: UUID(), apiClient: client)
    }

    private func responseJSON(withChange: Bool = true) -> String {
        let change =
            withChange
            ? """
            {"base_revision":7,"enabled":true,
            "stages":[{"stage_id":"spam","type":"classify","name":"Spam","config":{},
            "enabled":true,"halt":false,"accounts":null},
            {"stage_id":"rule-1","type":"match","name":"Newsletter","config":{"when":{"from":"a@b.c"}},
            "enabled":true,"halt":false,"accounts":null}],
            "title":"Change 2 rules: 1 added, 1 removed",
            "rules":[{"kind":"added","stage_id":"rule-1","name":"Newsletter","before_text":null,
            "after_text":"{}"},
            {"kind":"removed","stage_id":"old","name":"Old","before_text":"{}","after_text":null}]}
            """
            : "null"
        return """
            {"message":"Here is a rule","change":\(change),
            "preview":{"sample_size":100,"matched_before":2,"matched_after":9,
            "examples":[{"from_addr":"a@b.c","subject":"Hello"}]},
            "warnings":["Broad"],"model":"m","model_calls":2}
            """
    }

    private func propose(_ store: RuleAssistantStore, json: String) async {
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(json.utf8))
        store.promptText = "  these too  "
        store.send()
        XCTAssertEqual(store.phase, .running)
        await store.inFlight?.value
    }

    func testAProposalShowsTheChangeAndTheTrimmedPromptWasSent() async throws {
        let store = makeStore()
        await propose(store, json: responseJSON())
        guard case .result(let response, let change) = store.phase else { return XCTFail("\(store.phase)") }
        XCTAssertEqual(change.baseRevision, 7)
        XCTAssertEqual(change.rules.map(\.kindLabel), ["New", "Removed"])
        XCTAssertEqual(change.rules[1].afterText, nil)
        XCTAssertEqual(response.preview?.summaryLine, "Would have caught 9 of your last 100 mails (now: 2)")
        XCTAssertEqual(response.warnings, ["Broad"])
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.url?.path, "/api/pipeline/assistant")
        let body = try XCTUnwrap(MVStubURLProtocol.capturedRequest?.httpBody)
        XCTAssertEqual(try JSONDecoder().decode(RuleAssistantRequest.self, from: body).prompt, "these too")
    }

    func testAnAnswerWithoutAChangeIsTheEmptyState() async {
        let store = makeStore()
        await propose(store, json: responseJSON(withChange: false))
        XCTAssertEqual(store.phase, .empty("Here is a rule"))
    }

    func testABlankOrOverlongPromptCannotBeSent() {
        let store = makeStore()
        store.promptText = "   "
        XCTAssertFalse(store.canSend)
        store.promptText = String(repeating: "a", count: RuleAssistantRequest.maxPromptLength + 1)
        XCTAssertFalse(store.canSend)
        store.promptText = String(repeating: "a", count: RuleAssistantRequest.maxPromptLength)
        XCTAssertTrue(store.canSend)
    }

    func testAcceptingReplacesTheDocumentWithTheProposalsRevision() async throws {
        let store = makeStore()
        await propose(store, json: responseJSON())
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        store.accept()
        await store.inFlight?.value

        XCTAssertEqual(store.phase, .accepted)
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.httpMethod, "PUT")
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.url?.path, "/api/pipeline")
        let body = try XCTUnwrap(MVStubURLProtocol.capturedRequest?.httpBody)
        let sent = try JSONDecoder().decode(PipelineWriteRequest.self, from: body)
        XCTAssertEqual(sent.baseRevision, 7)
        XCTAssertTrue(sent.enabled)
        XCTAssertEqual(sent.stages.map(\.stageId), ["spam", "rule-1"])
        XCTAssertEqual(sent.stages[1].config["when"], .object(["from": .string("a@b.c")]))
    }

    func testAConflictOnAcceptSaysTheRulesChanged() async {
        let store = makeStore()
        await propose(store, json: responseJSON())
        MVStubURLProtocol.stub = .init(statusCode: 409, headers: [:], body: Data(#"{"detail":"stale"}"#.utf8))
        store.accept()
        await store.inFlight?.value
        XCTAssertEqual(store.phase, .failed(RuleAssistantStore.rulesChangedMessage))
        XCTAssertFalse(store.isAccepting)
    }

    func testAServerErrorOnProposeIsShown() async {
        let store = makeStore()
        MVStubURLProtocol.stub = .init(statusCode: 503, headers: [:], body: Data(#"{"detail":"No key"}"#.utf8))
        store.promptText = "x"
        store.send()
        await store.inFlight?.value
        XCTAssertEqual(store.phase, .failed("No key"))
    }

    func testCancellingWhileRunningDiscardsTheLateAnswer() async throws {
        let store = makeStore()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(responseJSON().utf8))
        store.promptText = "x"
        store.send()
        let running = store.inFlight
        store.cancel()
        await running?.value
        XCTAssertEqual(store.phase, .prompt)
        XCTAssertEqual(store.promptText, "")
    }

    func testASecondSendWhileRunningIsIgnored() {
        let store = makeStore()
        MVStubURLProtocol.stub = .init(statusCode: 200, headers: [:], body: Data(responseJSON().utf8))
        store.promptText = "x"
        store.send()
        let first = store.inFlight
        store.send()
        XCTAssertEqual(store.inFlight, first)
    }
}
