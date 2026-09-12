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
    func testOnlyOneOfColorAndBackgroundFailsTowardsLight() {
        XCTAssertEqual(CanvasPicker.pickCanvas(html: #"<div style="color: #111">x</div>"#, theme: .dark), .light)
    }

    func testColorAndBackgroundTogetherAreDarkSafe() {
        XCTAssertEqual(
            CanvasPicker.pickCanvas(html: #"<div style="color: #111; background: #fff">x</div>"#, theme: .dark), .dark)
    }

    func testNoDeclarationsFailTowardsLight() {
        XCTAssertEqual(CanvasPicker.pickCanvas(html: "<p>x</p>", theme: .dark), .light)
    }

    /// A styled span deep in the message is one link's colour, not the message's scheme.
    func testDeclarationsDeepInsideTheMessageDoNotCount() {
        let html =
            #"<div style="color: #111; background: #fff"><div><div><span style="color: red">x</span></div></div></div>"#
        XCTAssertEqual(CanvasPicker.pickCanvas(html: html, theme: .dark), .dark)
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
