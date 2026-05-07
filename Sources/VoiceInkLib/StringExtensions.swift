import Foundation

public extension String {
    /// Remove combining diacritical marks (accents) that Whisper sometimes adds to Russian text
    func stripCombiningAccents() -> String {
        String(unicodeScalars.filter { !("\u{0300}"..."\u{036F}").contains($0) })
    }

    /// Look up this string as a localization key in the package bundle.
    /// Returns the localized text for current system language, or the key itself if missing.
    /// Honors VOICEINK_LANG env var for forcing a specific language (testing).
    var localized: String {
        StringLocalizer.shared.string(for: self)
    }

    /// Localize with format arguments (e.g. "settings.smart_punctuation.ram_hint".localized(36))
    func localized(_ args: CVarArg...) -> String {
        String(format: StringLocalizer.shared.string(for: self), arguments: args)
    }
}

/// Manual localization that bypasses Bundle.preferredLocalizations cache.
/// Allows VOICEINK_LANG env var to force a specific language without restarting the process.
final class StringLocalizer {
    static let shared = StringLocalizer()

    private let bundle: Bundle

    private init() {
        // Determine target language
        let envLang = ProcessInfo.processInfo.environment["VOICEINK_LANG"]
        let langCode: String
        if let envLang = envLang, !envLang.isEmpty {
            langCode = envLang
        } else {
            // System preferred language — pick first one matching what we have, else fallback to en
            let supported: Set<String> = ["en", "ru"]
            let preferred = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) ?? "en"
            langCode = supported.contains(preferred) ? preferred : "en"
        }

        // Try to load specific lproj bundle
        if let path = Bundle.module.path(forResource: langCode, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            self.bundle = langBundle
        } else {
            // Fallback to default module bundle
            self.bundle = Bundle.module
        }
    }

    func string(for key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
