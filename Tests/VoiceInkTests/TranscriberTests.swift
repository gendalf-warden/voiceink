import XCTest
@testable import VoiceInkLib

final class TranscriberTests: XCTestCase {

    // MARK: - removeHallucinations

    func testRemovesTrailingProdolzhenie() {
        let input = "Это реальный текст. Продолжение следует..."
        XCTAssertEqual(Transcriber.removeHallucinations(input), "Это реальный текст.")
    }

    func testRemovesTrailingProdolzhenieWithEllipsis() {
        let input = "Некий текст Продолжение следует…"
        XCTAssertEqual(Transcriber.removeHallucinations(input), "Некий текст")
    }

    func testRemovesTrailingProdolzhenieNoPunctuation() {
        let input = "Текст продолжение следует"
        XCTAssertEqual(Transcriber.removeHallucinations(input), "Текст")
    }

    func testRemovesLoneYou() {
        XCTAssertEqual(Transcriber.removeHallucinations("you"), "")
        XCTAssertEqual(Transcriber.removeHallucinations("You."), "")
        XCTAssertEqual(Transcriber.removeHallucinations(" You "), "")
    }

    func testKeepsYouInContext() {
        let input = "Thank you very much"
        XCTAssertEqual(Transcriber.removeHallucinations(input), "Thank you very much")
    }

    func testRemovesTrailingThanksForWatching() {
        let input = "Here is the content. Thanks for watching!"
        XCTAssertEqual(Transcriber.removeHallucinations(input), "Here is the content.")
    }

    func testRemovesSubtitleCredits() {
        let input = "Текст речи. Субтитры создавал DimaS."
        XCTAssertEqual(Transcriber.removeHallucinations(input), "Текст речи.")
    }

    func testCleanTextPassesThrough() {
        let input = "Это обычный текст без галлюцинаций."
        XCTAssertEqual(Transcriber.removeHallucinations(input), input)
    }

    func testEmptyInput() {
        XCTAssertEqual(Transcriber.removeHallucinations(""), "")
    }

    func testCaseInsensitive() {
        let input = "Текст. ПРОДОЛЖЕНИЕ СЛЕДУЕТ..."
        XCTAssertEqual(Transcriber.removeHallucinations(input), "Текст.")
    }
}
