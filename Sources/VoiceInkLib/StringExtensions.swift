import Foundation

public extension String {
    /// Remove combining diacritical marks (accents) that Whisper sometimes adds to Russian text
    func stripCombiningAccents() -> String {
        String(unicodeScalars.filter { !("\u{0300}"..."\u{036F}").contains($0) })
    }
}
