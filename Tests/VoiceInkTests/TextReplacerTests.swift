import XCTest
@testable import VoiceInkLib

final class TextReplacerTests: XCTestCase {

    // MARK: - Basic

    func testEmptyDictionary() {
        XCTAssertEqual(TextReplacer.apply("Hello world", replacements: [:]), "Hello world")
    }

    func testEmptyText() {
        XCTAssertEqual(TextReplacer.apply("", replacements: ["a": "b"]), "")
    }

    func testSimpleReplacement() {
        XCTAssertEqual(
            TextReplacer.apply("Я был в Демале", replacements: ["Демале": "ДеМоле"]),
            "Я был в ДеМоле"
        )
    }

    // MARK: - Case-insensitive matching

    func testCaseInsensitiveMatch() {
        let dict = ["демале": "ДеМоле"]
        XCTAssertEqual(TextReplacer.apply("Демале и демале и ДЕМАЛЕ", replacements: dict),
                       "ДеМоле и ДеМоле и ДеМоле")
    }

    func testReplacementCasePreserved() {
        // "to" value is inserted verbatim regardless of "from" case
        let dict = ["вагена": "вагона"]
        XCTAssertEqual(TextReplacer.apply("ВАГЕНА", replacements: dict), "вагона")
    }

    // MARK: - Word boundary

    func testWordBoundaryDoesNotMatchInsideWord() {
        // "ваг" should NOT match inside "вагон"
        let dict = ["ваг": "X"]
        XCTAssertEqual(TextReplacer.apply("вагон и вагены", replacements: dict),
                       "вагон и вагены")
    }

    func testWordBoundaryMatchesAtStartAndEnd() {
        let dict = ["test": "TEST"]
        XCTAssertEqual(TextReplacer.apply("test foo test", replacements: dict),
                       "TEST foo TEST")
    }

    func testWordBoundaryWithPunctuation() {
        let dict = ["foo": "bar"]
        XCTAssertEqual(TextReplacer.apply("foo, foo. (foo) foo!", replacements: dict),
                       "bar, bar. (bar) bar!")
    }

    // MARK: - Multiple replacements

    func testMultipleReplacements() {
        let dict = ["Демале": "ДеМоле", "API": "АПИ"]
        let input = "В Демале мы используем API"
        let result = TextReplacer.apply(input, replacements: dict)
        XCTAssertTrue(result.contains("ДеМоле"))
        XCTAssertTrue(result.contains("АПИ"))
        XCTAssertFalse(result.contains("Демале"))
        XCTAssertFalse(result.contains("API"))
    }

    // MARK: - Edge cases

    func testEmptyKeyIgnored() {
        let dict = ["": "X", "foo": "bar"]
        XCTAssertEqual(TextReplacer.apply("foo bar", replacements: dict), "bar bar")
    }

    func testReplacementWithSpecialChars() {
        // User might want to map to text with $ — must not be treated as regex backreference
        let dict = ["price": "$10"]
        XCTAssertEqual(TextReplacer.apply("the price is high", replacements: dict),
                       "the $10 is high")
    }

    func testReplacementToEmpty() {
        // User can use this to delete words
        let dict = ["um": ""]
        XCTAssertEqual(TextReplacer.apply("I um think", replacements: dict),
                       "I  think")
    }

    func testEnglishLatinCyrillicMix() {
        let dict = ["TPI": "KPI", "Фиделио": "Fidelio"]
        let result = TextReplacer.apply("В Фиделио TPI был стабилен", replacements: dict)
        XCTAssertEqual(result, "В Fidelio KPI был стабилен")
    }
}
