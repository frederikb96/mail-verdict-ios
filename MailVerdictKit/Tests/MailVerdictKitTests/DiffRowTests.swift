import XCTest

@testable import MailVerdictKit

final class DiffRowTests: XCTestCase {

    func testARuleChangeDecodesItsDiffAndDefaultsItWhenAbsent() throws {
        let json = Data(
            """
            {"kind": "changed", "stage_id": "s", "name": "File", "before_text": "a", "after_text": "b",
             "diff": [{"op": "gap", "segments": [], "skipped": 4},
                      {"op": "added", "segments": [{"text": "b", "changed": true}]}]}
            """.utf8)
        let change = try JSONDecoder.mvDefault.decode(RuleAssistantRuleChange.self, from: json)
        XCTAssertEqual(change.diff.map(\.op), ["gap", "added"])
        XCTAssertEqual(change.diff[0].gapLabel, "⋯ 4 unchanged lines")
        XCTAssertEqual(change.diff[1].skipped, 0)

        let older = Data(#"{"kind": "moved", "stage_id": "s", "name": "File", "after_text": "a"}"#.utf8)
        XCTAssertEqual(try JSONDecoder.mvDefault.decode(RuleAssistantRuleChange.self, from: older).diff, [])
    }

    func testAGapOfOneLineIsSingular() {
        XCTAssertEqual(DiffRow(op: "gap", segments: [], skipped: 1).gapLabel, "⋯ 1 unchanged line")
    }
}
