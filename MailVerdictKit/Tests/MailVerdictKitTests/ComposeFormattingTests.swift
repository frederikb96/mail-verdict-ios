import Foundation
import XCTest

@testable import MailVerdictKit

final class ComposeFormattingTests: XCTestCase {

    private func text(_ blocks: [ComposeBlock]) -> NSMutableAttributedString {
        ComposeAttributedCodec.attributedString(from: ComposeDocument(blocks: blocks))
    }

    private func document(_ text: NSAttributedString, typing: ComposeFormatting.Attributes = [:]) -> ComposeDocument {
        ComposeAttributedCodec.document(from: text, trailingBlock: ComposeAttributedCodec.block(in: typing))
    }

    func testToggleMarkOnPartlyBoldSelectionBoldsAllThenUnboldsAll() {
        let storage = text([ComposeBlock(.paragraph, [.text("ab", [.bold]), .text("cd")])])
        var typing: ComposeFormatting.Attributes = [:]
        let all = NSRange(location: 0, length: 4)
        ComposeFormatting.toggleMark(.bold, in: storage, selection: all, typing: &typing)
        XCTAssertEqual(document(storage).blocks[0].runs, [.text("abcd", [.bold])])
        ComposeFormatting.toggleMark(.bold, in: storage, selection: all, typing: &typing)
        XCTAssertEqual(document(storage).blocks[0].runs, [.text("abcd")])
    }

    func testToggleListConvertsEverySelectedParagraphAndBack() {
        let storage = text([ComposeBlock(.paragraph, [.text("a")]), ComposeBlock(.paragraph, [.text("b")])])
        var typing: ComposeFormatting.Attributes = [:]
        let all = NSRange(location: 0, length: storage.length)
        ComposeFormatting.toggleList(.ordered, in: storage, selection: all, typing: &typing)
        XCTAssertEqual(
            document(storage).blocks.map(\.kind),
            Array(repeating: .listItem(.ordered, level: 0, checked: false), count: 2))
        ComposeFormatting.toggleList(.ordered, in: storage, selection: all, typing: &typing)
        XCTAssertEqual(document(storage).blocks.map(\.kind), [.paragraph, .paragraph])
    }

    func testReturnInEmptyNestedItemStepsOutOneLevelThenLeavesTheList() {
        let storage = text([
            ComposeBlock(.listItem(.bullet, level: 0, checked: false), [.text("a")]),
            ComposeBlock(.listItem(.bullet, level: 1, checked: false), []),
            ComposeBlock(.paragraph, [.text("after")]),
        ])
        var typing: ComposeFormatting.Attributes = [:]
        let caret = NSRange(location: 2, length: 0)
        XCTAssertTrue(ComposeFormatting.handleReturn(in: storage, selection: caret, typing: &typing))
        XCTAssertEqual(document(storage).blocks[1].kind, .listItem(.bullet, level: 0, checked: false))
        XCTAssertTrue(ComposeFormatting.handleReturn(in: storage, selection: caret, typing: &typing))
        XCTAssertEqual(document(storage).blocks[1].kind, .paragraph)
        XCTAssertFalse(ComposeFormatting.handleReturn(in: storage, selection: caret, typing: &typing))
    }

    /// Splitting a ticked item makes an unticked one, as every checklist editor does.
    func testNewlineAfterTickedItemStartsUnticked() {
        let storage = text([ComposeBlock(.listItem(.checklist, level: 0, checked: true), [.text("done")])])
        var typing = ComposeAttributedCodec.attributes(
            marks: [], link: nil, block: .listItem(.checklist, level: 0, checked: true))
        storage.append(NSAttributedString(string: "\n", attributes: typing))
        ComposeFormatting.didInsertParagraphBreak(at: 4, in: storage, typing: &typing)
        XCTAssertEqual(
            document(storage, typing: typing).blocks.map(\.kind),
            [.listItem(.checklist, level: 0, checked: true), .listItem(.checklist, level: 0, checked: false)])
    }

    func testBackspaceAtStartOfListItemTakesTheFormatOffInsteadOfMerging() {
        let storage = text([
            ComposeBlock(.paragraph, [.text("a")]),
            ComposeBlock(.listItem(.bullet, level: 0, checked: false), [.text("b")]),
        ])
        var typing: ComposeFormatting.Attributes = [:]
        XCTAssertTrue(
            ComposeFormatting.handleBackspace(deleting: NSRange(location: 1, length: 1), in: storage, typing: &typing))
        XCTAssertEqual(document(storage).blocks.map(\.kind), [.paragraph, .paragraph])
        XCTAssertFalse(
            ComposeFormatting.handleBackspace(deleting: NSRange(location: 1, length: 1), in: storage, typing: &typing))
    }

    /// A character typed at a paragraph's start inherits the paragraph above's attributes; the
    /// paragraph's own kind, held by its terminating newline, must win.
    func testNormalizingGivesATypedFirstCharacterItsOwnParagraphsKind() {
        let storage = text([
            ComposeBlock(.paragraph, [.text("a")]), ComposeBlock(.quote, [.text("b")]),
            ComposeBlock(.paragraph, [.text("c")]),
        ])
        storage.insert(
            NSAttributedString(string: "X", attributes: [.mvBlock: ComposeBlockKind.paragraph.attributeValue]), at: 2)
        ComposeFormatting.normalizeBlocks(in: storage, range: NSRange(location: 2, length: 1), typing: [:])
        XCTAssertEqual(document(storage).blocks[1], ComposeBlock(.quote, [.text("Xb")]))
    }

    func testIndentNeverSkipsALevel() {
        let storage = text([
            ComposeBlock(.listItem(.bullet, level: 0, checked: false), [.text("a")]),
            ComposeBlock(.listItem(.bullet, level: 0, checked: false), [.text("b")]),
        ])
        var typing: ComposeFormatting.Attributes = [:]
        let second = NSRange(location: 2, length: 0)
        ComposeFormatting.changeIndent(by: 1, in: storage, selection: second, typing: &typing)
        ComposeFormatting.changeIndent(by: 1, in: storage, selection: second, typing: &typing)
        XCTAssertEqual(document(storage).blocks[1].kind, .listItem(.bullet, level: 1, checked: false))
        ComposeFormatting.changeIndent(by: 1, in: storage, selection: NSRange(location: 0, length: 0), typing: &typing)
        XCTAssertEqual(document(storage).blocks[0].kind, .listItem(.bullet, level: 0, checked: false))
    }

    func testLinkWithoutSelectionInsertsTheURLAsItsText() {
        let storage = text([ComposeBlock(.paragraph, [.text("go ")])])
        var typing: ComposeFormatting.Attributes = [.mvBlock: "p"]
        let selection = ComposeFormatting.setLink(
            "https://x.test", in: storage, selection: NSRange(location: 3, length: 0), typing: &typing)
        XCTAssertEqual(selection, NSRange(location: 17, length: 0))
        XCTAssertEqual(
            document(storage).blocks[0].runs, [.text("go "), .text("https://x.test", link: "https://x.test")])
        _ = ComposeFormatting.setLink("", in: storage, selection: NSRange(location: 5, length: 0), typing: &typing)
        XCTAssertEqual(document(storage).blocks[0].runs, [.text("go https://x.test")])
    }
}
