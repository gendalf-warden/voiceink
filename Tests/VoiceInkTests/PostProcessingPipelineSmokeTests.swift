import XCTest
@testable import VoiceInkLib

/// Smoke tests that exercise the full post-processing pipeline with a mock LLM.
/// These are NOT WAV-based integration tests — they verify the mode/prompt/guard
/// contract that production code relies on. Real WAV-based regression lives in
/// TESTS.md (manual) and `scripts/smoke-test-modes.sh` (optional, requires LLM).
final class PostProcessingPipelineSmokeTests: XCTestCase {

    // MARK: - .off → no LLM call, raw text passes through

    func testOffModeBypassesLLM() async {
        let mock = MockLLMProcessor()
        let result = await PostProcessingPipeline.apply(
            rawText: "hello world",
            mode: .off,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertEqual(result, "hello world")
        XCTAssertEqual(mock.callCount, 0, ".off mode must not call the LLM")
    }

    func testNilProcessorPassesThrough() async {
        let result = await PostProcessingPipeline.apply(
            rawText: "anything",
            mode: .smart,
            translateTarget: "en",
            processor: nil
        )
        XCTAssertEqual(result, "anything")
    }

    func testEmptyInputPassesThrough() async {
        let mock = MockLLMProcessor()
        let result = await PostProcessingPipeline.apply(
            rawText: "",
            mode: .smart,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertEqual(result, "")
        XCTAssertEqual(mock.callCount, 0, "empty input must not call the LLM")
    }

    // MARK: - Each mode sends its own system prompt

    func testSmartSendsCombinedPrompt() async {
        let mock = MockLLMProcessor(response: "Hello, world.")
        _ = await PostProcessingPipeline.apply(
            rawText: "hello world",
            mode: .smart,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertEqual(mock.callCount, 1)
        let prompt = mock.lastSystemPrompt?.lowercased() ?? ""
        XCTAssertTrue(prompt.contains("punctuation"), ".smart prompt mentions punctuation")
        XCTAssertTrue(prompt.contains("grammar"), ".smart prompt mentions grammar")
    }

    func testTranslatePromptIncludesTargetLanguage() async {
        let mock = MockLLMProcessor(response: "Здравствуй, мир.")
        _ = await PostProcessingPipeline.apply(
            rawText: "Hello world",
            mode: .translate,
            translateTarget: "ru",
            processor: mock
        )
        XCTAssertTrue(mock.lastSystemPrompt?.contains("Russian") ?? false)
    }

    func testTranslateToArmenianMentionsArmenian() async {
        let mock = MockLLMProcessor(response: "Բարև աշխարհ:")
        _ = await PostProcessingPipeline.apply(
            rawText: "Hello world",
            mode: .translate,
            translateTarget: "hy",
            processor: mock
        )
        XCTAssertTrue(mock.lastSystemPrompt?.contains("Armenian") ?? false,
                      "translate(hy) prompt must mention Armenian")
    }

    // MARK: - Length guard

    func testLengthGuardTripsFor3xOverflow() async {
        let mock = MockLLMProcessor(response: String(repeating: "verbose ", count: 100))
        let raw = "short input"
        let result = await PostProcessingPipeline.apply(
            rawText: raw,
            mode: .smart,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertEqual(result, raw, "3x overflow should fall back to raw")
    }

    func testLengthGuardAllowsModerateExpansion() async {
        let raw = "hello world how are you"
        let mock = MockLLMProcessor(response: "Hello, world. How are you?")
        let result = await PostProcessingPipeline.apply(
            rawText: raw,
            mode: .smart,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertEqual(result, "Hello, world. How are you?")
    }

    func testLengthGuardSkippedForTranslate() async {
        let raw = "Hi"
        let longTranslation = "Здравствуйте, как у вас дела сегодня?"
        let mock = MockLLMProcessor(response: longTranslation)
        let result = await PostProcessingPipeline.apply(
            rawText: raw,
            mode: .translate,
            translateTarget: "ru",
            processor: mock
        )
        XCTAssertEqual(result, longTranslation, "translate mode must not be gated by 3x length")
    }

    // MARK: - Script guard

    func testScriptGuardCatchesUnwantedTranslation() async {
        let raw = "Привет, мир"
        let mock = MockLLMProcessor(response: "Hello, world")
        let result = await PostProcessingPipeline.apply(
            rawText: raw,
            mode: .smart,
            translateTarget: "en",
            processor: mock,
            expectedScriptLanguage: "ru"
        )
        XCTAssertEqual(result, raw, "script guard should reject LLM-translated output")
    }

    func testScriptGuardSkippedForTranslateMode() async {
        let raw = "Привет, мир"
        let mock = MockLLMProcessor(response: "Hello, world")
        let result = await PostProcessingPipeline.apply(
            rawText: raw,
            mode: .translate,
            translateTarget: "en",
            processor: mock,
            expectedScriptLanguage: "ru"
        )
        XCTAssertEqual(result, "Hello, world", "translate mode must allow script change")
    }

    func testScriptGuardAllowsMatchingScript() async {
        let raw = "привет мир"
        let mock = MockLLMProcessor(response: "Привет, мир.")
        let result = await PostProcessingPipeline.apply(
            rawText: raw,
            mode: .smart,
            translateTarget: "en",
            processor: mock,
            expectedScriptLanguage: "ru"
        )
        XCTAssertEqual(result, "Привет, мир.")
    }

    // MARK: - LLM failure → fail safe

    func testLLMErrorReturnsRawText() async {
        let raw = "important user dictation"
        let mock = MockLLMProcessor(error: MockError.simulated)
        let result = await PostProcessingPipeline.apply(
            rawText: raw,
            mode: .smart,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertEqual(result, raw, "LLM errors must not lose the user's dictation")
    }

    // MARK: - Prompt content rules (digits, language, no-translate)

    /// The combined .smart prompt MUST instruct the LLM to preserve digits and
    /// the source language. Catches prompt drift even without reference WAVs.
    func testSmartPromptContractFlags() {
        let prompt = PostProcessingMode.smart.systemPrompt() ?? ""
        XCTAssertTrue(
            prompt.lowercased().contains("digit") || prompt.lowercased().contains("number"),
            ".smart prompt must instruct to keep numbers as digits"
        )
        XCTAssertTrue(prompt.contains("DO NOT translate"),
                      ".smart prompt must forbid translation explicitly")
    }
}

// MARK: - Mock helpers

final class MockLLMProcessor: LLMProcessor {
    var responseFor: ((String, String) -> String)?
    var fixedResponse: String?
    var error: Error?
    private(set) var callCount = 0
    private(set) var lastUserText: String?
    private(set) var lastSystemPrompt: String?

    init(response: String? = nil, error: Error? = nil) {
        self.fixedResponse = response
        self.error = error
    }

    func process(text: String, systemPrompt: String) async throws -> String {
        callCount += 1
        lastUserText = text
        lastSystemPrompt = systemPrompt
        if let error = error { throw error }
        if let resp = responseFor?(text, systemPrompt) { return resp }
        return fixedResponse ?? text
    }
}

enum MockError: Error { case simulated }
