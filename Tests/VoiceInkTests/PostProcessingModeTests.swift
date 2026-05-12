import XCTest
@testable import VoiceInkLib

final class PostProcessingModeTests: XCTestCase {

    // MARK: - systemPrompt(translateTarget:)

    func testOffReturnsNilPrompt() {
        XCTAssertNil(PostProcessingMode.off.systemPrompt())
        XCTAssertNil(PostProcessingMode.off.systemPrompt(translateTarget: "en"))
    }

    func testSmartPromptCoversPunctuationGrammarAndLists() {
        let prompt = PostProcessingMode.smart.systemPrompt() ?? ""
        let lower = prompt.lowercased()
        XCTAssertTrue(lower.contains("punctuation"), ".smart must mention punctuation")
        XCTAssertTrue(lower.contains("grammar"), ".smart must mention grammar")
        XCTAssertTrue(lower.contains("bullet") || lower.contains("list"),
                      ".smart must mention bullet/list reformatting")
        XCTAssertTrue(prompt.contains("DO NOT translate"),
                      ".smart prompt must forbid translation explicitly")
        XCTAssertTrue(lower.contains("digit") || lower.contains("number"),
                      ".smart must instruct digits stay as digits")
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
            ("en", "English"), ("ru", "Russian"), ("hy", "Armenian"),
            ("es", "Spanish"), ("fr", "French"), ("de", "German"),
            ("zh", "Chinese"), ("ja", "Japanese"), ("ar", "Arabic")
        ]
        for (code, name) in cases {
            let prompt = PostProcessingMode.translate.systemPrompt(translateTarget: code) ?? ""
            XCTAssertTrue(prompt.contains(name),
                          "translate(\(code)) prompt should contain language name '\(name)'")
        }
    }

    func testTranslatePromptUnknownCodeFallsBackToCode() {
        let prompt = PostProcessingMode.translate.systemPrompt(translateTarget: "xyz") ?? ""
        XCTAssertTrue(prompt.contains("xyz"),
                      "unknown code should appear verbatim in prompt")
    }

    // MARK: - Translation target catalog

    func testTranslationTargetsIncludeArmenianExcludeUkrainian() {
        let codes = Set(translationTargetLanguages.map(\.code))
        XCTAssertTrue(codes.contains("hy"), "Armenian must be available as a target")
        XCTAssertFalse(codes.contains("uk"), "Ukrainian was removed; should not appear")
    }

    // MARK: - Codable

    func testRoundTripAllCases() throws {
        for mode in PostProcessingMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(PostProcessingMode.self, from: data)
            XCTAssertEqual(decoded, mode, "round trip should preserve \(mode.rawValue)")
        }
    }

    /// Raw values are persisted to disk and must NOT change without a migration.
    /// `.smart`'s raw value stays `"punctuation"` so v0.3b configs with the
    /// legacy `punctuationEnabled` boolean still map to a usable mode.
    func testRawValueStability() {
        XCTAssertEqual(PostProcessingMode.off.rawValue, "off")
        XCTAssertEqual(PostProcessingMode.smart.rawValue, "punctuation")
        XCTAssertEqual(PostProcessingMode.translate.rawValue, "translate")
    }

    func testAllCasesCount() {
        // Bump only when intentionally adding/removing modes
        XCTAssertEqual(PostProcessingMode.allCases.count, 3)
    }
}
