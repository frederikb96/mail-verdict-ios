import XCTest

@testable import MailVerdictKit

final class ReaderCanvasTests: XCTestCase {

    func testLightThemeIsAlwaysLight() {
        XCTAssertEqual(
            CanvasPicker.pickCanvas(html: "<style>@media (prefers-color-scheme: dark) {}</style>", theme: .light),
            .light)
    }

    func testDeclaredDarkSupportOpensDark() {
        XCTAssertEqual(
            CanvasPicker.pickCanvas(html: #"<div style="color-scheme: light dark">x</div>"#, theme: .dark), .dark)
    }

    /// A template setting only its text colour gets the dark host's background — unreadable.
    func testOnlyOneOfColorAndBackgroundStaysLight() {
        XCTAssertEqual(CanvasPicker.pickCanvas(html: #"<div style="color: #111">x</div>"#, theme: .dark), .light)
    }

    /// D15 dropped the old "paired colour and background is safe" exemption: a dark canvas is
    /// never guaranteed to match whatever background the template assumed, so any declared
    /// colour at all keeps the message light.
    func testColorAndBackgroundTogetherStillStaysLight() {
        XCTAssertEqual(
            CanvasPicker.pickCanvas(html: #"<div style="color: #111; background: #fff">x</div>"#, theme: .dark),
            .light)
    }

    /// A colour rule inside a `<style>` block is as much a declared colour as an inline one.
    func testStyleBlockColorRuleStaysLight() {
        let html = #"<style>.x { color: #111; }</style><div class="x">x</div>"#
        XCTAssertEqual(CanvasPicker.pickCanvas(html: html, theme: .dark), .light)
    }

    /// Newsletters from before CSS commonly painted colour with these attributes instead.
    func testLegacyBgcolorAttributeStaysLight() {
        let html = ##"<table bgcolor="#ffffff"><tr><td>x</td></tr></table>"##
        XCTAssertEqual(CanvasPicker.pickCanvas(html: html, theme: .dark), .light)
    }

    /// Per D15, a message with no colour declaration anywhere has nothing for a dark canvas to
    /// clash with, so it opens dark like Apple Mail renders plain mail — the opposite of the
    /// web's fail-towards-light default.
    func testNoDeclarationsOpenDarkLikeAppleMail() {
        XCTAssertEqual(CanvasPicker.pickCanvas(html: "<p>x</p>", theme: .dark), .dark)
    }

    /// D15 has no "too deep to count" exemption — a colour declared anywhere keeps the message
    /// light, even a single styled span several levels in.
    func testDeclarationDeepInsideTheMessageStillStaysLight() {
        let html = "<div><div><div><span style=\"color: red\">x</span></div></div></div>"
        XCTAssertEqual(CanvasPicker.pickCanvas(html: html, theme: .dark), .light)
    }

    func testCanvasChoicesDropTheOldestPastCapacity() {
        var choices = MVCanvasChoices()
        let first = UUID()
        choices.set(.dark, for: first)
        for _ in 0..<2000 { choices.set(.light, for: UUID()) }
        XCTAssertNil(choices.choice(for: first))
        XCTAssertEqual(choices.entries.count, 2000)
    }

    func testChangingAChoiceKeepsItFromBeingDropped() {
        var choices = MVCanvasChoices()
        let first = UUID()
        choices.set(.dark, for: first)
        for _ in 0..<1999 { choices.set(.light, for: UUID()) }
        choices.set(.light, for: first)
        choices.set(.light, for: UUID())
        XCTAssertEqual(choices.choice(for: first), .light)
    }
}
