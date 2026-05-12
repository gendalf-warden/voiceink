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
            mode: .punctuation,
            translateTarget: "en",
            processor: nil
        )
        XCTAssertEqual(result, "anything")
    }

    func testEmptyInputPassesThrough() async {
        let mock = MockLLMProcessor()
        let result = await PostProcessingPipeline.apply(
            rawText: "",
            mode: .punctuation,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertEqual(result, "")
        XCTAssertEqual(mock.callCount, 0, "empty input must not call the LLM")
    }

    // MARK: - Each mode sends its own system prompt

    func testPunctuationSendsPunctuationPrompt() async {
        let mock = MockLLMProcessor(response: "Hello, world.")
        _ = await PostProcessingPipeline.apply(
            rawText: "hello world",
            mode: .punctuation,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertEqual(mock.callCount, 1)
        XCTAssertTrue(mock.lastSystemPrompt?.lowercased().contains("punctuation") ?? false)
    }

    func testGrammarSendsGrammarPrompt() async {
        let mock = MockLLMProcessor(response: "Corrected text.")
        _ = await PostProcessingPipeline.apply(
            rawText: "moi knigi novie",
            mode: .grammar,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertTrue(mock.lastSystemPrompt?.lowercased().contains("grammar") ?? false)
    }

    func testListSendsListPrompt() async {
        let mock = MockLLMProcessor(response: "- a\n- b")
        _ = await PostProcessingPipeline.apply(
            rawText: "a and b",
            mode: .list,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertTrue((mock.lastSystemPrompt?.lowercased().contains("list") ?? false)
                      || (mock.lastSystemPrompt?.lowercased().contains("bullet") ?? false))
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

    // MARK: - Length guard

    func testLengthGuardTripsFor3xOverflow() async {
        let mock = MockLLMProcessor(response: String(repeating: "verbose ", count: 100))
        let raw = "short input"
        let result = await PostProcessingPipeline.apply(
            rawText: raw,
            mode: .punctuation,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertEqual(result, raw, "3x overflow should fall back to raw")
    }

    func testLengthGuardAllowsModerateExpansion() async {
        // Adding punctuation can grow text slightly — guard should not trip
        let raw = "hello world how are you"
        let mock = MockLLMProcessor(response: "Hello, world. How are you?")
        let result = await PostProcessingPipeline.apply(
            rawText: raw,
            mode: .punctuation,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertEqual(result, "Hello, world. How are you?")
    }

    func testLengthGuardSkippedForTranslate() async {
        // Translation may legitimately produce much longer or shorter text
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
        // Russian raw → LLM erroneously translates to English. With expected="ru",
        // pipeline should reject and return raw.
        let raw = "Привет, мир"
        let mock = MockLLMProcessor(response: "Hello, world")
        let result = await PostProcessingPipeline.apply(
            rawText: raw,
            mode: .punctuation,
            translateTarget: "en",
            processor: mock,
            expectedScriptLanguage: "ru"
        )
        XCTAssertEqual(result, raw, "script guard should reject LLM-translated output")
    }

    func testScriptGuardSkippedForTranslateMode() async {
        // In translate mode, script SHOULD change — guard must be disabled
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
            mode: .punctuation,
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
            mode: .punctuation,
            translateTarget: "en",
            processor: mock
        )
        XCTAssertEqual(result, raw, "LLM errors must not lose the user's dictation")
    }

    // MARK: - Reference-text content rules (smoke checks the prompt contract)

    /// Prompts in non-translate modes MUST explicitly preserve digits, English words,
    /// and (where applicable) original language. These are the contract checks the
    /// user listed: "цифры, спецсимволы, англицизмы". They live here so prompt drift
    /// is caught even without reference WAVs.
    func testNonTranslatePromptsPreserveDigitsAndLanguage() {
        for mode in [PostProcessingMode.punctuation, .grammar, .list] {
            let prompt = mode.systemPrompt() ?? ""
            XCTAssertTrue(
                prompt.lowercased().contains("digit") || prompt.lowercased().contains("number"),
                "\(mode.rawValue) prompt must instruct to keep numbers as digits"
            )
            if mode != .punctuation {
                XCTAssertTrue(prompt.contains("DO NOT translate"),
                              "\(mode.rawValue) prompt must forbid translation explicitly")
            }
        }
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
