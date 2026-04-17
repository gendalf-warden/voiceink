import Foundation

public class Transcriber {
    private let config: Config
    private var serverProcess: Process?
    private let serverPort = 8178
    private let serverHost = "127.0.0.1"
    public private(set) var isServerRunning = false

    public init(config: Config) {
        self.config = config
    }

    /// Start whisper-server in background (model stays loaded in memory)
    public func startServer() throws {
        // Use whisperServerPath if set, otherwise derive from whisperCliPath
        let serverPath = !config.whisperServerPath.isEmpty
            ? config.whisperServerPath
            : config.whisperCliPath.replacingOccurrences(of: "whisper-cli", with: "whisper-server")

        guard FileManager.default.isExecutableFile(atPath: serverPath) else {
            throw TranscriberError.whisperNotFound(serverPath)
        }
        guard FileManager.default.fileExists(atPath: config.whisperModelPath) else {
            throw TranscriberError.modelNotFound(config.whisperModelPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)

        // Fewer threads on low-memory systems to reduce pressure
        let threads = Config.systemRAMGB < 16 ? 4 : 8

        var args = [
            "-m", config.whisperModelPath,
            "--host", serverHost,
            "--port", String(serverPort),
            "--no-timestamps",
            "-t", String(threads),
        ]
        args += ["-l", config.language]
        process.arguments = args

        // Capture stderr for diagnostics, suppress stdout
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        serverProcess = process
        log("Server starting on \(serverHost):\(serverPort) (threads: \(threads))...", tag: "Transcriber")

        // Wait for server to be ready (longer timeout on low-memory systems)
        let maxAttempts = Config.systemRAMGB < 16 ? 180 : 60  // 90s vs 30s
        isServerRunning = waitForServer(maxAttempts: maxAttempts)

        if !isServerRunning {
            // Log stderr to help diagnose
            let stderrData = stderrPipe.fileHandleForReading.availableData
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            if !stderrStr.isEmpty {
                let lastLines = stderrStr.components(separatedBy: "\n").suffix(5).joined(separator: "\n")
                log("Server stderr (last lines):\n\(lastLines)", tag: "Transcriber")
            }

            // Check if process crashed
            if !process.isRunning {
                log("Server process exited with code \(process.terminationStatus)", tag: "Transcriber")
            }
        }
    }

    public func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
        isServerRunning = false
        log("Server stopped", tag: "Transcriber")
    }

    public func transcribe(audioURL: URL, timeout: TimeInterval = 30, languageOverride: String? = nil) async throws -> String {
        let language = languageOverride ?? config.language
        let (text, _) = try await sendInference(
            audioURL: audioURL,
            timeout: timeout,
            language: language,
            responseFormat: "text"
        )
        let stripped = Transcriber.stripForeignChars(text, language: language)
        return Transcriber.removeHallucinations(stripped)
    }

    /// Transcribe and detect language. Used on first chunk of a file to lock language for subsequent chunks.
    /// Returns (cleaned text, detected language ISO code like "ru"/"en").
    public func transcribeDetectLanguage(audioURL: URL, timeout: TimeInterval = 30) async throws -> (text: String, language: String) {
        let (text, language) = try await sendInference(
            audioURL: audioURL,
            timeout: timeout,
            language: "auto",
            responseFormat: "verbose_json"
        )
        return (Transcriber.removeHallucinations(text), Transcriber.toISOCode(language))
    }

    /// Convert Whisper's language output to ISO 639-1 code.
    /// Whisper sometimes returns full names ("russian") and sometimes ISO codes ("ru").
    public static func toISOCode(_ lang: String) -> String {
        let normalized = lang.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Already ISO 639-1 (2-char lowercase)
        if normalized.count == 2 { return normalized }
        // Common full names → ISO
        let map: [String: String] = [
            "russian": "ru", "english": "en", "chinese": "zh",
            "japanese": "ja", "korean": "ko", "spanish": "es",
            "french": "fr", "german": "de", "italian": "it",
            "portuguese": "pt", "dutch": "nl", "polish": "pl",
            "ukrainian": "uk", "turkish": "tr", "arabic": "ar",
            "hindi": "hi", "vietnamese": "vi", "thai": "th",
            "indonesian": "id", "greek": "el", "hebrew": "he",
            "czech": "cs", "hungarian": "hu", "romanian": "ro",
            "swedish": "sv", "norwegian": "no", "danish": "da",
            "finnish": "fi", "bulgarian": "bg", "serbian": "sr",
            "croatian": "hr", "slovak": "sk", "slovenian": "sl",
        ]
        return map[normalized] ?? normalized
    }

    /// Check if the text's script matches the expected language.
    /// Used to detect mis-auto-detected chunks without a verbose_json round-trip.
    /// Returns true if at least `minRatio` of alphabetic chars are in the expected script.
    public static func scriptMatches(_ text: String, language: String, minRatio: Double = 0.3) -> Bool {
        let lang = language.lowercased()
        // For very short text (< 5 alphabetic chars), can't reliably tell — accept
        let alphabetic = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if alphabetic.count < 5 { return true }

        let matchCount = alphabetic.filter { scalar in
            let v = scalar.value
            switch lang {
            case "ru", "uk", "bg", "sr", "mk", "be":
                // Cyrillic: U+0400-U+04FF (+ extensions)
                return (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v)
            case "en", "es", "fr", "de", "it", "pt", "nl", "pl", "cs", "sk", "sv", "no", "da", "fi", "hu", "ro", "tr", "id", "vi":
                // Latin: basic + supplements
                return (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v)
                    || (0x00C0...0x024F).contains(v)
            case "zh", "ja", "ko":
                return (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v)
                    || (0x4E00...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v)
            case "ar", "he":
                return (0x0590...0x06FF).contains(v)
            case "el":
                return (0x0370...0x03FF).contains(v)
            default:
                return true  // unknown language — don't flag
            }
        }.count

        let ratio = Double(matchCount) / Double(alphabetic.count)
        return ratio >= minRatio
    }

    /// Strip characters that shouldn't appear in text of the given language.
    /// Defense against Whisper hallucinating CJK/other foreign characters on unclear audio.
    public static func stripForeignChars(_ text: String, language: String?) -> String {
        guard let lang = language?.lowercased(), !lang.isEmpty, lang != "auto" else { return text }
        // CJK Unicode ranges (Chinese/Japanese/Korean)
        // Hiragana: U+3040-U+309F, Katakana: U+30A0-U+30FF
        // CJK Unified Ideographs: U+4E00-U+9FFF, U+3400-U+4DBF
        // Hangul: U+AC00-U+D7AF, Hangul Jamo: U+1100-U+11FF
        // We strip these for non-CJK target languages
        let cjkLanguages: Set<String> = ["zh", "ja", "ko"]
        if cjkLanguages.contains(lang) { return text }

        let scalars = text.unicodeScalars.filter { scalar in
            let v = scalar.value
            let isCJK =
                (0x3040...0x309F).contains(v) || // Hiragana
                (0x30A0...0x30FF).contains(v) || // Katakana
                (0x4E00...0x9FFF).contains(v) || // CJK Unified
                (0x3400...0x4DBF).contains(v) || // CJK Extension A
                (0xAC00...0xD7AF).contains(v) || // Hangul Syllables
                (0x1100...0x11FF).contains(v)    // Hangul Jamo
            return !isCJK
        }
        let result = String(String.UnicodeScalarView(scalars))
        // Collapse multiple spaces from removed characters
        return result.replacingOccurrences(of: "  ", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Low-level inference call. Returns (text, detectedLanguage). detectedLanguage is "" for non-verbose formats.
    private func sendInference(audioURL: URL, timeout: TimeInterval, language: String, responseFormat: String) async throws -> (String, String) {
        let url = URL(string: "http://\(serverHost):\(serverPort)/inference")!
        let audioData = try Data(contentsOf: audioURL)

        let boundary = UUID().uuidString
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n".data(using: .utf8)!)
        body.append("0.0\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(responseFormat)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(language)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriberError.processFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }

        if responseFormat == "text" {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (text, "")
        } else {
            // verbose_json: { "text": "...", "language": "ru", "segments": [...] }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let detectedLang = (json["language"] as? String) ?? ""
            return (text, detectedLang)
        }
    }

    /// Remove common Whisper hallucinations that appear on silence/unclear audio.
    /// These are phrases Whisper was trained on (captions, subtitles) and emits
    /// when it has nothing to transcribe.
    public static func removeHallucinations(_ text: String) -> String {
        // Known hallucination patterns (case-insensitive, matched at end OR as standalone)
        let patterns = [
            "продолжение следует",
            "продолжение следует...",
            "продолжение следует…",
            "субтитры подогнал",
            "субтитры делал",
            "редактор субтитров",
            "корректор субтитров",
            "thanks for watching",
            "thank you for watching",
            "субтитры создавал",
            "субтитры сделал",
        ]
        var result = text
        // Remove "you" or "You." if the entire output is just that (silence hallucination)
        let trimmed = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if trimmed.lowercased() == "you" {
            return ""
        }
        // Remove hallucination phrases. Two cases:
        // A) Trailing hallucination after real text — match whitespace + pattern, keep real text
        // B) Standalone hallucination (entire chunk is just the phrase) — match from start
        for pattern in patterns {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            // Case A: trailing (real text ... [ws] Pattern ...)
            if let regex = try? NSRegularExpression(
                pattern: "\\s+\(escaped).*$",
                options: [.caseInsensitive]
            ) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
            // Case B: standalone (^ Pattern ...) — only if the entire (trimmed) text matches
            if let regex = try? NSRegularExpression(
                pattern: "^\(escaped)[\\s\\.,!?…\\-—]*$",
                options: [.caseInsensitive]
            ) {
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                    result = ""
                }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func waitForServer(maxAttempts: Int = 60) -> Bool {
        let url = URL(string: "http://\(serverHost):\(serverPort)/")!
        for i in 1...maxAttempts {
            Thread.sleep(forTimeInterval: 0.5)
            var request = URLRequest(url: url)
            request.timeoutInterval = 1

            let semaphore = DispatchSemaphore(value: 0)
            var ready = false

            let task = URLSession.shared.dataTask(with: request) { _, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    ready = true
                }
                semaphore.signal()
            }
            task.resume()
            semaphore.wait()

            if ready {
                log("Server ready (took \(String(format: "%.1f", Double(i) * 0.5))s)", tag: "Transcriber")
                return true
            }
        }
        log("Server did not become ready in time", tag: "Transcriber")
        return false
    }

    public enum TranscriberError: Error, LocalizedError {
        case whisperNotFound(String)
        case modelNotFound(String)
        case processFailed(String)

        public var errorDescription: String? {
            switch self {
            case .whisperNotFound(let path): return "whisper-server not found at: \(path)"
            case .modelNotFound(let path): return "Model not found at: \(path)"
            case .processFailed(let msg): return "Transcription failed: \(msg)"
            }
        }
    }
}
