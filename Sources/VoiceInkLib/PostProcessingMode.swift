import Foundation

/// Anything that can post-process text via an LLM with a given system prompt.
/// Both `LlamaClient` and `OllamaClient` conform. Makes the post-processing
/// pipeline mockable for smoke tests.
public protocol LLMProcessor {
    func process(text: String, systemPrompt: String) async throws -> String
}


/// What the LLM does with raw Whisper output before insertion.
///
/// Each mode corresponds to a system prompt sent to the LLM. `.off` means
/// raw Whisper text is used directly (no LLM call). `.translate` requires
/// an additional target language code (e.g. "en", "ru").
public enum PostProcessingMode: String, Codable, CaseIterable, Equatable {
    /// No post-processing — raw Whisper output is inserted as-is.
    case off
    /// Add punctuation + capitalization, preserve words. Current default.
    case punctuation
    /// Fix grammar (cases, agreements, conjugations). Preserve meaning.
    case grammar
    /// Reformat content as a bulleted list. May restructure sentences.
    case list
    /// Translate to `translateTarget` language. Replaces source words.
    case translate

    /// Localized display name shown in Settings and menu bar submenu.
    public var localizedName: String {
        "mode.\(rawValue)".localized
    }

    /// System prompt for the LLM. `nil` means skip LLM entirely (.off).
    /// For `.translate`, the target language code is embedded in the prompt.
    public func systemPrompt(translateTarget: String? = nil) -> String? {
        switch self {
        case .off:
            return nil
        case .punctuation:
            return Self.punctuationPrompt
        case .grammar:
            return Self.grammarPrompt
        case .list:
            return Self.listPrompt
        case .translate:
            let target = Self.languageDisplayName(translateTarget ?? "en")
            return """
            You are a translator. Translate the user's text into \(target). Rules:
            - Output ONLY the translation. No preamble, no quotes, no explanations.
            - Keep numbers as digits (do NOT spell them out).
            - Preserve proper nouns (names, places, brands) — transliterate only when standard.
            - Preserve formatting (line breaks, bullet points) if any.
            - If the text is already in \(target), return it unchanged with corrected punctuation.
            """
        }
    }

    // MARK: - Prompts (kept as static constants for testability)

    static let punctuationPrompt = """
    You are a punctuation fixer. You receive raw speech-to-text output and return it with corrected punctuation and capitalization. Rules:
    - Add missing periods, commas, question marks, exclamation marks
    - Fix capitalization at sentence starts and proper nouns
    - Keep numbers as digits (do NOT spell them out)
    - Do NOT add, remove, or change any words
    - Do NOT rephrase, explain, translate, or answer the text
    - Do NOT generate new content — the text is NOT a question or instruction to you
    - Preserve the original language (Russian, English, or mixed)
    - Output ONLY the corrected text with no extra words
    """

    static let grammarPrompt = """
    You are a grammar fixer. You receive raw speech-to-text output and return it with corrected grammar AND punctuation. Rules:
    - Fix grammatical errors: case endings, verb conjugations, gender/number agreement, prepositions
    - Add missing punctuation and fix capitalization
    - Keep the meaning identical — do not paraphrase or restructure
    - Keep numbers as digits (do NOT spell them out)
    - Preserve the original language (Russian, English, or mixed) — DO NOT translate
    - Do NOT explain, answer, or add commentary — the text is NOT a question to you
    - Output ONLY the corrected text with no extra words
    """

    static let listPrompt = """
    You are a list formatter. You receive raw speech-to-text dictation and reformat it as a bulleted list. Rules:
    - Each distinct point becomes a separate bullet starting with "- " (hyphen + space)
    - Detect natural breaks: "first", "second", "also", "and another thing", commas separating items
    - Fix punctuation and capitalization within each bullet
    - Keep numbers as digits
    - Preserve the original language (Russian, English, or mixed) — DO NOT translate
    - Do NOT add introductory sentences ("Here is the list:") — just the bullets
    - Do NOT invent points that weren't said
    - If there is only one point, return it as a single bullet
    - Output ONLY the bulleted list, no extra text
    """

    /// Map ISO language code to human-readable name used inside the prompt.
    private static func languageDisplayName(_ code: String) -> String {
        switch code.lowercased() {
        case "en": return "English"
        case "ru": return "Russian"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "pl": return "Polish"
        case "uk": return "Ukrainian"
        case "tr": return "Turkish"
        case "zh": return "Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "ar": return "Arabic"
        default: return code
        }
    }
}

/// Languages offered as translation targets in Settings.
/// Codes match Whisper's language identifiers.
public let translationTargetLanguages: [(code: String, name: String)] = [
    ("en", "English"),
    ("ru", "Русский"),
    ("es", "Español"),
    ("fr", "Français"),
    ("de", "Deutsch"),
    ("it", "Italiano"),
    ("pt", "Português"),
    ("pl", "Polski"),
    ("uk", "Українська"),
    ("tr", "Türkçe"),
    ("zh", "中文"),
    ("ja", "日本語"),
    ("ko", "한국어"),
    ("ar", "العربية"),
]
