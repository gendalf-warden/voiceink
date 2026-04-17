import XCTest
@testable import VoiceInkLib

final class StringExtensionsTests: XCTestCase {

    // MARK: - stripCombiningAccents()

    func testStripAccentsFromRussian() {
        // Whisper sometimes adds combining acute accent (U+0301) to Russian vowels
        let input = "привет\u{0301} мир\u{0301}"
        XCTAssertEqual(input.stripCombiningAccents(), "привет мир")
    }

    func testStripMultipleAccents() {
        // Combining grave (0300), acute (0301), circumflex (0302)
        let input = "a\u{0300}b\u{0301}c\u{0302}"
        XCTAssertEqual(input.stripCombiningAccents(), "abc")
    }

    func testPassthroughCleanRussian() {
        let input = "Привет, мир!"
        XCTAssertEqual(input.stripCombiningAccents(), input)
    }

    func testPassthroughEnglish() {
        let input = "Hello, world!"
        XCTAssertEqual(input.stripCombiningAccents(), input)
    }

    func testPassthroughEmpty() {
        XCTAssertEqual("".stripCombiningAccents(), "")
    }

    func testPreservesNonCombiningUnicode() {
        // Emoji and CJK should pass through
        let input = "текст 🎤 test"
        XCTAssertEqual(input.stripCombiningAccents(), input)
    }
}
