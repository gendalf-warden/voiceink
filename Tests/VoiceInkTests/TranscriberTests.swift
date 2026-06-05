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

    func testStandaloneHallucination() {
        // Whole chunk is just the hallucination — remove completely
        XCTAssertEqual(Transcriber.removeHallucinations("Продолжение следует..."), "")
        XCTAssertEqual(Transcriber.removeHallucinations("продолжение следует…"), "")
        XCTAssertEqual(Transcriber.removeHallucinations("Thanks for watching"), "")
        XCTAssertEqual(Transcriber.removeHallucinations("Thanks for watching!"), "")
    }

    func testStandaloneHallucinationWithLeadingSpace() {
        XCTAssertEqual(Transcriber.removeHallucinations("  Продолжение следует... "), "")
    }

    func testRemovesStandaloneThankYou() {
        // Bare "Thank you." on its own is a silence hallucination (Anna's bug)
        XCTAssertEqual(Transcriber.removeHallucinations("Thank you."), "")
        XCTAssertEqual(Transcriber.removeHallucinations("thank you"), "")
        XCTAssertEqual(Transcriber.removeHallucinations("  Thank you  "), "")
        XCTAssertEqual(Transcriber.removeHallucinations("Thanks"), "")
        XCTAssertEqual(Transcriber.removeHallucinations("Bye bye"), "")
    }

    func testKeepsThankYouInSentence() {
        // "thank you" as standalone-only must NOT be stripped as a trailing tail
        let input = "I really want to thank you for this."
        XCTAssertEqual(Transcriber.removeHallucinations(input), input)
    }

    func testRemovesRepeatedWordLoop() {
        // Keyboard clicks transcribed as a repetition loop (Anna's bug)
        XCTAssertEqual(Transcriber.removeHallucinations("click click click click"), "")
        XCTAssertEqual(Transcriber.removeHallucinations("Click click click."), "")
        XCTAssertEqual(Transcriber.removeHallucinations("так так так так"), "")
    }

    func testKeepsNonLoopText() {
        // Fewer than 3 repeats, or distinct words — keep
        XCTAssertEqual(Transcriber.removeHallucinations("no no"), "no no")
        XCTAssertEqual(Transcriber.removeHallucinations("так точно"), "так точно")
    }

    func testRemovesSpasiboZaProsmotr() {
        XCTAssertEqual(Transcriber.removeHallucinations("Спасибо за просмотр"), "")
        XCTAssertEqual(Transcriber.removeHallucinations("Вот текст. Спасибо за просмотр."), "Вот текст.")
    }

    // MARK: - toISOCode

    func testISOCodeFullNames() {
        XCTAssertEqual(Transcriber.toISOCode("russian"), "ru")
        XCTAssertEqual(Transcriber.toISOCode("English"), "en")
        XCTAssertEqual(Transcriber.toISOCode("CHINESE"), "zh")
    }

    func testISOCodePassesThroughISO() {
        XCTAssertEqual(Transcriber.toISOCode("ru"), "ru")
        XCTAssertEqual(Transcriber.toISOCode("en"), "en")
    }

    func testISOCodeUnknownFallback() {
        XCTAssertEqual(Transcriber.toISOCode("klingon"), "klingon")
    }

    // MARK: - stripForeignChars

    func testStripChineseFromRussianText() {
        let input = "Русский текст 你知道 продолжение"
        XCTAssertEqual(Transcriber.stripForeignChars(input, language: "ru"), "Русский текст продолжение")
    }

    func testStripJapaneseFromEnglish() {
        let input = "Hello さようなら world"
        XCTAssertEqual(Transcriber.stripForeignChars(input, language: "en"), "Hello world")
    }

    func testStripHangulFromRussian() {
        let input = "Текст 안녕 ещё"
        XCTAssertEqual(Transcriber.stripForeignChars(input, language: "ru"), "Текст ещё")
    }

    func testPreservesChineseWhenLangIsChinese() {
        let input = "你好 world"
        XCTAssertEqual(Transcriber.stripForeignChars(input, language: "zh"), "你好 world")
    }

    func testAutoLanguagePassesThrough() {
        let input = "Текст 你知道 продолжение"
        XCTAssertEqual(Transcriber.stripForeignChars(input, language: "auto"), input)
    }

    func testNilLanguagePassesThrough() {
        let input = "Текст 你知道 продолжение"
        XCTAssertEqual(Transcriber.stripForeignChars(input, language: nil), input)
    }

    func testPreservesRussianAndEnglish() {
        let input = "Открой Excel и сохрани файл в формате XLSX"
        XCTAssertEqual(Transcriber.stripForeignChars(input, language: "ru"), input)
    }

    // MARK: - scriptMatches

    func testScriptMatchesRussianText() {
        XCTAssertTrue(Transcriber.scriptMatches("Это русский текст", language: "ru"))
    }

    func testScriptMatchesRussianWithEnglishWords() {
        // Real code-switching: mostly Russian with English terms — should match ru
        XCTAssertTrue(Transcriber.scriptMatches(
            "Выгрузим данные в Excel и пришлем по email", language: "ru"))
    }

    func testScriptDoesNotMatchEnglishOnlyForRussian() {
        // Pure English text when expecting Russian — mismatch
        XCTAssertFalse(Transcriber.scriptMatches(
            "To be two bases were identical", language: "ru"))
    }

    func testScriptMatchesShortText() {
        // Very short text — accepted regardless (insufficient signal)
        XCTAssertTrue(Transcriber.scriptMatches("Yes", language: "ru"))
        XCTAssertTrue(Transcriber.scriptMatches("", language: "ru"))
    }

    func testScriptMatchesEnglish() {
        XCTAssertTrue(Transcriber.scriptMatches("Hello world this is English", language: "en"))
    }

    func testScriptDoesNotMatchRussianForEnglish() {
        XCTAssertFalse(Transcriber.scriptMatches("Это чисто русский текст", language: "en"))
    }

    func testScriptUnknownLanguageAcceptsAll() {
        // Unknown language code — don't flag anything
        XCTAssertTrue(Transcriber.scriptMatches("Some text", language: "klingon"))
    }
}
