import XCTest
@testable import VoiceInkLib

final class PostProcessingModeTests: XCTestCase {

    // MARK: - systemPrompt(translateTarget:)

    func testOffReturnsNilPrompt() {
        XCTAssertNil(PostProcessingMode.off.systemPrompt())
        XCTAssertNil(PostProcessingMode.off.systemPrompt(translateTarget: "en"))
    }

    func testPunctuationPromptMentionsPunctuation() {
        let prompt = PostProcessingMode.punctuation.systemPrompt() ?? ""
        XCTAssertTrue(prompt.lowercased().contains("punctuation"), "punctuation prompt should mention punctuation")
        XCTAssertTrue(prompt.contains("Do NOT add, remove, or change any words"),
                      "punctuation prompt must forbid word changes")
    }

    func testGrammarPromptMentionsGrammar() {
        let prompt = PostProcessingMode.grammar.systemPrompt() ?? ""
        XCTAssertTrue(prompt.lowercased().contains("grammar"), "grammar prompt should mention grammar")
        XCTAssertTrue(prompt.contains("DO NOT translate"),
                      "grammar prompt must explicitly forbid translation")
    }

    func testListPromptMentionsBullets() {
        let prompt = PostProcessingMode.list.systemPrompt() ?? ""
        XCTAssertTrue(prompt.lowercased().contains("bullet") || prompt.contains("- "),
                      "list prompt should mention bullets")
        XCTAssertTrue(prompt.contains("DO NOT translate"),
                      "list prompt must explicitly forbid translation")
    }

    func testTranslatePromptIncludesTargetLanguageName() {
        let prompt = PostProcessingMode.translate.systemPrompt(translateTarget: "ru") ?? ""
        XCTAssertTrue(prompt.contains("Russian"), "translate prompt should name the target language")
        XCTAssertFalse(prompt.contains("English"), "translate prompt should not name irrelevant languages")
    }

    func testTranslatePromptDefaultsToEnglish() {
        let prompt = PostProcessingMode.translate.systemPrompt() ?? ""
        XCTAssertTrue(prompt.contains("English"),
                      "translate prompt with no target should default to English")
    }

    func testTranslatePromptKnownLanguageCodes() {
        let cases: [(String, String)] = [
            ("en", "English"), ("ru", "Russian"), ("es", "Spanish"),
            ("fr", "French"), ("de", "German"), ("zh", "Chinese"),
            ("ja", "Japanese"), ("ar", "Arabic")
        ]
        for (code, name) in cases {
            let prompt = PostProcessingMode.translate.systemPrompt(translateTarget: code) ?? ""
            XCTAssertTrue(prompt.contains(name),
                          "translate(\(code)) prompt should contain language name '\(name)'")
        }
    }

    func testTranslatePromptUnknownCodeFallsBackToCode() {
        // Unknown ISO code should still produce a prompt — degraded but functional
        let prompt = PostProcessingMode.translate.systemPrompt(translateTarget: "xyz") ?? ""
        XCTAssertTrue(prompt.contains("xyz"),
                      "unknown code should appear verbatim in prompt")
    }

    // MARK: - Codable

    func testRoundTripAllCases() throws {
        for mode in PostProcessingMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(PostProcessingMode.self, from: data)
            XCTAssertEqual(decoded, mode, "round trip should preserve \(mode.rawValue)")
        }
    }

    func testRawValueStability() {
        // These raw values are persisted to disk and must NOT change without a migration
        XCTAssertEqual(PostProcessingMode.off.rawValue, "off")
        XCTAssertEqual(PostProcessingMode.punctuation.rawValue, "punctuation")
        XCTAssertEqual(PostProcessingMode.grammar.rawValue, "grammar")
        XCTAssertEqual(PostProcessingMode.list.rawValue, "list")
        XCTAssertEqual(PostProcessingMode.translate.rawValue, "translate")
    }

    func testAllCasesCount() {
        // Catches accidental enum changes; bump when intentionally adding/removing modes
        XCTAssertEqual(PostProcessingMode.allCases.count, 5)
    }
}
