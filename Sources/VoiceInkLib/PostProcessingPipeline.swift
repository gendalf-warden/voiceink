import Foundation

/// Stateless helper that applies a `PostProcessingMode` to raw text using an `LLMProcessor`.
/// Handles the same hallucination guards as the dictation and file-transcription pipelines
/// so smoke tests can exercise the contract without spinning up a real LLM.
public enum PostProcessingPipeline {

    /// Apply `mode` to `rawText`. If mode is `.off` or no processor is available, returns `rawText`.
    /// On LLM failure or guard trip, returns `rawText` (fail-safe).
    ///
    /// Guards (matching `AppDelegate` and `FileTranscriptionManager`):
    /// - **Length**: skipped for `.translate` (length is unpredictable); otherwise output
    ///   capped at 3× input.
    /// - **Script**: if `expectedScriptLanguage` is set and the LLM output's script no
    ///   longer matches while the input's did, the input is used instead. Disabled for
    ///   `.translate` (the script change is intentional).
    public static func apply(
        rawText: String,
        mode: PostProcessingMode,
        translateTarget: String,
        processor: LLMProcessor?,
        expectedScriptLanguage: String? = nil
    ) async -> String {
        guard let processor = processor, mode != .off, !rawText.isEmpty,
              let prompt = mode.systemPrompt(translateTarget: translateTarget)
        else {
            return rawText
        }

        let processed: String
        do {
            processed = try await processor.process(text: rawText, systemPrompt: prompt)
        } catch {
            return rawText
        }

        // Length guard — skip for .translate (translation length is unpredictable)
        if mode != .translate && processed.count > rawText.count * 3 {
            return rawText
        }

        // Script guard — only meaningful when mode is supposed to preserve language
        if mode != .translate, let expected = expectedScriptLanguage,
           !Transcriber.scriptMatches(processed, language: expected),
           Transcriber.scriptMatches(rawText, language: expected) {
            return rawText
        }

        return processed
    }
}
