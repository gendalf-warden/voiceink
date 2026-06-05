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

    /// Resolve the bundled whisper-server executable path used by this Transcriber.
    private var resolvedServerPath: String {
        !config.whisperServerPath.isEmpty
            ? config.whisperServerPath
            : config.whisperCliPath.replacingOccurrences(of: "whisper-cli", with: "whisper-server")
    }

    /// Kill orphaned whisper-server processes from previous app sessions. Call
    /// at app launch BEFORE the first `startServer()`. Safe no-op if no orphans.
    /// MUST NOT be called from in-session restart paths — `restartServer()` has
    /// its own coordination (NSLock + coalesce window) and would deadlock if
    /// `kill()` happened mid-flight.
    public func killOrphanedServersAtLaunch() {
        ProcessHygiene.killOrphans(
            executablePath: resolvedServerPath,
            port: serverPort,
            label: "whisper-server"
        )
    }

    /// Start whisper-server in background (model stays loaded in memory)
    public func startServer() throws {
        let serverPath = resolvedServerPath

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
        // B: on ≤8 GB machines, disable flash-attention. Metal flash-attn has known
        // deadlocks on unified-memory systems with constrained VRAM (ggml-metal
        // resource-set init enters retry/sleep loop, holds inference mutex,
        // all subsequent /inference requests block on std::mutex::lock).
        if Config.systemRAMGB <= 8 {
            args += ["-nfa"]
            log("Low-RAM: disabling whisper flash-attention (-nfa) to avoid Metal deadlock", tag: "Transcriber")
        }
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

    /// Stop the server process and WAIT for it to actually exit before returning.
    /// `process.terminate()` sends SIGTERM but doesn't wait; a Metal-deadlocked whisper-server
    /// can ignore SIGTERM (its Metal thread is stuck in usleep retry-loop and never returns
    /// to the signal handler). We give it 3 s, then SIGKILL. Without this, restart() spawns
    /// a new process while the old one is still alive → 2+ processes accumulate per restart,
    /// port 8178 collisions, RAM pressure.
    public func stopServer() {
        guard let p = serverProcess else {
            isServerRunning = false
            return
        }
        let pid = p.processIdentifier
        p.terminate()
        serverProcess = nil
        isServerRunning = false

        // Wait up to 3 s for graceful exit
        let deadline = Date().addingTimeInterval(3.0)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            log("SIGTERM ignored — sending SIGKILL to whisper-server (pid \(pid))", tag: "Transcriber")
            kill(pid, SIGKILL)
            // Give SIGKILL a moment to land
            let killDeadline = Date().addingTimeInterval(1.0)
            while p.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        log("Server stopped (pid \(pid))", tag: "Transcriber")
    }

    /// Restart counter for diagnostics + breaker. After N restarts in one session
    /// we stop trying — the deadlock is permanent for this run.
    private var restartCount: Int = 0
    private let maxRestarts: Int = 10
    private let restartLock = NSLock()
    /// Timestamp of the last successful restart. Used to coalesce racing watchdog calls:
    /// with concurrency=2 (or any parallel ASR), several requests can time out
    /// simultaneously and all enter `restartServer()`. The NSLock serializes them,
    /// but without coalescing each waiter does its OWN redundant restart, killing
    /// the server that the previous caller just brought back up.
    private var lastRestartAt: Date? = nil
    private let restartCoalesceWindow: TimeInterval = 5.0

    /// Proactive-restart counter. Increments on every `/inference` call. When it
    /// reaches `proactiveRestartInterval`, a restart happens BEFORE the deadlock
    /// at ~150 inferences. Goal: keep `__ggml_metal_rsets_init` from accumulating
    /// the resource sets that eventually cause the hang. Cheaper to spend 10 s on
    /// a clean restart than to wait for a 60 s timeout + watchdog retry.
    private var inferenceCount: Int = 0
    private let inferenceCountLock = NSLock()
    private let proactiveRestartInterval: Int = 100

    /// Reset the watchdog breaker. Call at the start of each new file transcription
    /// so the per-session restart budget refreshes.
    public func resetWatchdog() {
        restartLock.lock()
        if restartCount > 0 {
            log("Watchdog reset: previous session used \(restartCount)/\(maxRestarts) restarts", tag: "Transcriber")
        }
        restartCount = 0
        lastRestartAt = nil
        restartLock.unlock()

        inferenceCountLock.lock()
        inferenceCount = 0
        inferenceCountLock.unlock()
    }

    /// Increment the proactive counter and return true when it crosses the threshold.
    /// Counter wraps to 0 on threshold crossing so the next 100 inferences trigger
    /// another preemptive restart. Thread-safe under concurrency=2 pipelined ASR.
    private func shouldProactiveRestart() -> Bool {
        inferenceCountLock.lock()
        defer { inferenceCountLock.unlock() }
        inferenceCount += 1
        if inferenceCount >= proactiveRestartInterval {
            inferenceCount = 0
            return true
        }
        return false
    }

    /// Restart whisper-server proactively (not in response to a timeout). Does NOT
    /// count against the watchdog breaker — proactive restarts aren't failures.
    /// Coalescing window applies: if a peer restart happened within the last 5 s,
    /// this is a no-op.
    public func proactiveRestart() {
        restartLock.lock()
        defer { restartLock.unlock() }
        if let last = lastRestartAt, Date().timeIntervalSince(last) < restartCoalesceWindow {
            let age = Date().timeIntervalSince(last)
            log("Proactive restart coalesced — peer restart \(String(format: "%.1f", age))s ago", tag: "Transcriber")
            return
        }
        log("Proactive restart (after \(proactiveRestartInterval) inferences) — preempting Metal deadlock...", tag: "Transcriber")
        stopServer()
        Thread.sleep(forTimeInterval: 1.0)
        do {
            try startServer()
            if isServerRunning {
                lastRestartAt = Date()
            }
        } catch {
            log("Proactive restart failed: \(error)", tag: "Transcriber")
        }
    }

    /// Kill and restart the whisper-server process. Used by the watchdog when /inference
    /// times out (typically Metal-backend deadlock in `ggml_metal_rsets_init`).
    /// Coalesces concurrent restart requests: if a successful restart happened within
    /// the last `restartCoalesceWindow` seconds, this is a no-op (the caller's retry
    /// will hit the freshly-restarted server).
    /// Returns false if the breaker has tripped or restart itself failed.
    @discardableResult
    public func restartServer() -> Bool {
        restartLock.lock()
        defer { restartLock.unlock() }

        // Coalesce: a peer watchdog call just restarted the server. Don't double-restart.
        if let last = lastRestartAt, Date().timeIntervalSince(last) < restartCoalesceWindow {
            let age = Date().timeIntervalSince(last)
            log("Restart coalesced — peer restart finished \(String(format: "%.1f", age))s ago; server is fresh", tag: "Transcriber")
            return isServerRunning
        }

        guard restartCount < maxRestarts else {
            log("Restart breaker tripped (\(restartCount)/\(maxRestarts)) — giving up", tag: "Transcriber")
            return false
        }
        restartCount += 1
        log("Restarting whisper-server (attempt \(restartCount)/\(maxRestarts))...", tag: "Transcriber")
        stopServer()  // now properly waits + SIGKILL fallback
        Thread.sleep(forTimeInterval: 1.0)  // let Metal/GPU resources unwind
        do {
            try startServer()
            if isServerRunning {
                lastRestartAt = Date()
            }
            return isServerRunning
        } catch {
            log("Restart failed: \(error)", tag: "Transcriber")
            return false
        }
    }

    public func transcribe(audioURL: URL, timeout: TimeInterval = 30, languageOverride: String? = nil) async throws -> String {
        let language = languageOverride ?? config.language
        let (text, _) = try await sendInferenceWithWatchdog(
            audioURL: audioURL,
            timeout: timeout,
            language: language,
            responseFormat: "text"
        )
        let stripped = Transcriber.stripForeignChars(text, language: language)
        let cleaned = Transcriber.removeHallucinations(stripped)
        Transcriber.logFilterAction(before: stripped, after: cleaned)
        return cleaned
    }

    /// Log what the hallucination/foreign-char filter removed. The removed text is
    /// rejected junk (never inserted into the user's document), so logging it verbatim
    /// is privacy-safe and is exactly what's needed to diagnose phantom-text reports.
    /// Truncated to keep the log readable. No-op when nothing changed.
    static func logFilterAction(before: String, after: String) {
        guard before != after else { return }
        func clip(_ s: String) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ")
            return one.count > 80 ? String(one.prefix(80)) + "…" : one
        }
        if after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log("Hallucination filter dropped entire output: \"\(clip(before))\"", tag: "Transcriber")
        } else {
            log("Hallucination filter trimmed: \"\(clip(before))\" → \"\(clip(after))\"", tag: "Transcriber")
        }
    }

    /// Transcribe and detect language. Used on first chunk of a file to lock language for subsequent chunks.
    /// Returns (cleaned text, detected language ISO code like "ru"/"en").
    public func transcribeDetectLanguage(audioURL: URL, timeout: TimeInterval = 30) async throws -> (text: String, language: String) {
        let (text, language) = try await sendInferenceWithWatchdog(
            audioURL: audioURL,
            timeout: timeout,
            language: "auto",
            responseFormat: "verbose_json"
        )
        let cleaned = Transcriber.removeHallucinations(text)
        Transcriber.logFilterAction(before: text, after: cleaned)
        return (cleaned, Transcriber.toISOCode(language))
    }

    /// Wrap `sendInference` with a watchdog: on URL timeout, assume whisper-server is hung
    /// (typically Metal-backend deadlock), kill+restart the process, and retry the request
    /// once. If the second attempt also times out, propagate the error so the caller logs
    /// it as an ASR failure and writes an empty chunk.
    private func sendInferenceWithWatchdog(
        audioURL: URL, timeout: TimeInterval, language: String, responseFormat: String
    ) async throws -> (String, String) {
        // Proactive restart BEFORE the call: preempt Metal deadlock by cycling the
        // server every N inferences. With concurrency=2 the second in-flight request
        // may be killed by this restart — that's fine: the watchdog catch-block below
        // will see networkConnectionLost, coalesce against the just-finished restart,
        // and retry once against the fresh server.
        if shouldProactiveRestart() {
            proactiveRestart()
        }
        do {
            return try await sendInference(
                audioURL: audioURL, timeout: timeout,
                language: language, responseFormat: responseFormat
            )
        } catch {
            // Hang signature: URLError.timedOut, or any URLSession error after the server stopped
            // responding mid-stream. Both warrant a restart attempt.
            let isHang: Bool = {
                if let url = error as? URLError {
                    return url.code == .timedOut
                        || url.code == .networkConnectionLost
                        || url.code == .cannotConnectToHost
                }
                return false
            }()
            guard isHang else { throw error }

            log("Watchdog: whisper-server unresponsive (\(error.localizedDescription)) — restarting and retrying", tag: "Transcriber")
            let restarted = restartServer()
            guard restarted else {
                throw TranscriberError.processFailed("whisper-server hung and restart failed")
            }
            // One retry only. If this also fails the caller will write an empty chunk.
            return try await sendInference(
                audioURL: audioURL, timeout: timeout,
                language: language, responseFormat: responseFormat
            )
        }
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
        // Patterns safe to strip BOTH as a trailing tail after real text AND as a
        // standalone chunk. These are caption/subtitle artifacts that essentially
        // never occur inside genuine dictation, so stripping mid-text is safe.
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
            "спасибо за просмотр",
            "субтитры создавал",
            "субтитры сделал",
        ]
        // Patterns removed ONLY when they are the entire output (standalone).
        // These (e.g. a bare "thank you") legitimately end real sentences, so we must
        // never strip them as a trailing tail — only when the whole chunk is just this.
        let standaloneOnly = [
            "you",
            "thank you",
            "thanks",
            "bye",
            "bye bye",
            "пока",
            "спасибо",
        ]
        var result = text
        // A whole output made of one short word repeated (≥3×) is a Whisper repetition
        // loop on noise — e.g. keyboard clicks transcribed as "click click click click".
        if isRepeatedWordLoop(result) {
            return ""
        }
        // Remove standalone-only hallucinations: drop the whole output if (ignoring
        // surrounding whitespace/punctuation) it equals one of these phrases.
        let bareTrimmed = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if standaloneOnly.contains(bareTrimmed.lowercased()) {
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

    /// True when the entire output is one short token repeated ≥3 times — a Whisper
    /// repetition loop on noise (e.g. keyboard clicks → "click click click click").
    /// Conservative: requires a single distinct token, repeated, and short (≤12 chars)
    /// so real phrases like "ha ha ha" survive only if genuinely repeated nonsense.
    static func isRepeatedWordLoop(_ text: String) -> Bool {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard tokens.count >= 3 else { return false }
        guard let first = tokens.first, first.count <= 12 else { return false }
        return tokens.allSatisfy { $0 == first }
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
