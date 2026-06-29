import AppKit
import Foundation
import UniformTypeIdentifiers

/// Orchestrates file transcription with chunked pipeline:
/// file picker → convert → split into chunks → transcribe + LLM per chunk → stream to result window.
///
/// Uses parallel pipeline: up to `concurrency` ASR requests in flight, with LLM pipelined
/// (runs while next ASR is being processed). concurrency=2 is the sweet spot — higher values
/// saturate the GPU without gain. concurrency=1 gives pure pipeline (A), 2+ gives parallel (B).
public class FileTranscriptionManager {
    private var resultWindow: TranscriptionResultWindowController?
    private let converter = AudioConverter()
    /// Returns the current llama client (may be nil before lazy load or after release)
    public var llamaClientProvider: (() -> LlamaClient?)?
    /// Returns the current ollama client (may be nil before lazy load or after release)
    public var ollamaClientProvider: (() -> OllamaClient?)?
    /// Called before pipeline starts. Should ensure LLM is loaded. Returns true if LLM is available.
    public var onLLMNeeded: (() async -> Bool)?
    /// Called after pipeline finishes. Should release LLM if it was lazy-loaded.
    public var onLLMRelease: (() async -> Void)?
    /// Post-processing mode applied to each chunk's transcription
    public var mode: PostProcessingMode = .smart
    /// Target language for .translate mode (ISO 639-1 code)
    public var translateTarget: String = "en"
    /// User replacements applied after Whisper, before LLM
    public var replacements: [String: String] = [:]
    /// Number of concurrent ASR/LLM requests (2 = ~60% faster than sequential baseline).
    /// On ≤8 GB machines AppDelegate sets this to 1 — two parallel whisper inferences
    /// each consume ~0.5-1 GB working memory, on top of the loaded model + LLM, which
    /// exceeds the budget and causes swap/OOM. Sequential is slower but stable.
    public var concurrency: Int = 2

    /// Low-memory mode: run ASR for all chunks first, then LLM for all chunks, instead
    /// of pipelining (which keeps whisper + llm working sets active simultaneously).
    /// AppDelegate sets this to true on ≤8 GB machines. Slower but lower peak RAM.
    public var lowMemoryMode: Bool = false

    private var llamaClient: LlamaClient? { llamaClientProvider?() }
    private var ollamaClient: OllamaClient? { ollamaClientProvider?() }

    /// Thread-safe counter for tracking completed chunks across concurrent tasks
    private actor ChunkCounter {
        private var count = 0
        func increment() -> Int { count += 1; return count }
    }

    /// Chunk results indexed by position, streamed to the window
    public struct ChunkResult {
        public let index: Int
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        public let text: String
    }

    public init() {}

    public func startFileTranscription(transcriber: Transcriber) {
        // Force VoiceInk to the front BEFORE running the picker. Otherwise the picker
        // opens behind whatever app currently owns the front (the menu bar item click
        // doesn't activate the accessory app on its own), and the user has to hunt for
        // the panel on another window or another Space.
        NSApp.showDock()  // activationPolicy = .regular + activate(ignoringOtherApps:)

        // Show file picker
        let panel = NSOpenPanel()
        panel.title = "Select audio or video file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.level = .modalPanel  // force above other floating windows on the active Space

        var types: [UTType] = []
        for ext in AudioConverter.supportedExtensions {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        panel.allowedContentTypes = types

        // One more activation right before modal — Dock-launch may have completed
        // asynchronously and the panel needs a focused app at runModal() time.
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            // Picker dismissed without selection — hide dock if no other windows are open.
            NSApp.hideDockIfNoWindows()
            return
        }

        log("File transcription: \(fileURL.lastPathComponent)", tag: "FileTranscription")

        // Show result window
        let result = TranscriptionResultWindowController()
        result.show()
        result.setStatus("Opening \(fileURL.lastPathComponent)...")
        self.resultWindow = result

        Task {
            await self.runPipeline(fileURL: fileURL, transcriber: transcriber, window: result)
        }
    }

    private func runPipeline(fileURL: URL, transcriber: Transcriber, window: TranscriptionResultWindowController) async {
        // Fresh restart budget per file transcription.
        transcriber.resetWatchdog()
        do {
            let pipelineStart = Date()

            // Step 1: Duration
            let duration = await converter.duration(fileURL: fileURL)
            let durationStr = duration > 0 ? String(format: "%.0f", duration) + "s" : "unknown"
            log("File duration: \(durationStr)", tag: "FileTranscription")

            // Step 2: Convert to 16kHz mono WAV
            window.setStatus("Converting audio (\(durationStr))...")
            let convertStart = Date()
            let wavURL = try await converter.convert(fileURL: fileURL)
            let convertTime = Date().timeIntervalSince(convertStart)
            log("Conversion: \(String(format: "%.1f", convertTime))s", tag: "FileTranscription")
            defer { try? FileManager.default.removeItem(at: wavURL) }

            // Step 3: Split into chunks
            window.setStatus("Splitting audio into chunks...")
            let chunks = try converter.splitIntoChunks(wavURL: wavURL)
            let totalChunks = chunks.count
            log("Chunks: \(totalChunks)", tag: "FileTranscription")
            defer {
                for chunk in chunks where chunk.url != wavURL {
                    try? FileManager.default.removeItem(at: chunk.url)
                }
            }

            window.beginStreaming(totalChunks: totalChunks, totalDuration: duration)

            // Step 3.5: Lazy-load LLM if needed (when dictation toggle is off but file mode != .off,
            // LLM is not warm at startup — load it now, release after pipeline finishes).
            //
            // Low-RAM exception: defer the LLM load until AFTER the ASR phase (see the
            // lowMemoryMode branch below). Loading it here keeps the llama-server working set
            // (~2.5 GB for qwen2.5-3b) resident in RAM throughout the whisper ASR pass, which
            // defeats the sequential-phase mitigation and causes swap thrash → whisper/llama
            // timeouts on ≤8 GB machines.
            let needsLLM = mode != .off
            if needsLLM, !lowMemoryMode, let onNeeded = onLLMNeeded {
                window.setStatus("Loading post-processing model...")
                let ready = await onNeeded()
                if !ready {
                    log("LLM unavailable — files will use raw Whisper output", tag: "FileTranscription")
                }
            }

            // Step 4a: Detect language on first chunk — sets the "expected" language for the file.
            // Each chunk is still auto-detected (for legitimate code-switching), but if a chunk's
            // detection differs from expected, we re-transcribe with expected language forced
            // (rejects rare hallucinations where Whisper mis-detects a noisy chunk as English/Chinese).
            var expectedLanguage: String? = nil
            if chunks.count > 1 {
                window.setStatus("Detecting language...")
                do {
                    let firstChunk = chunks[0]
                    let timeout = max(60, firstChunk.duration * 2)
                    let (_, detected) = try await transcriber.transcribeDetectLanguage(
                        audioURL: firstChunk.url, timeout: timeout)
                    if !detected.isEmpty {
                        expectedLanguage = detected
                        log("Expected language: \(detected) (mismatched chunks will be re-transcribed)", tag: "FileTranscription")
                    }
                } catch {
                    log("Language detection failed: \(error)", tag: "FileTranscription")
                }
            }

            // Step 4b: Pipeline (parallel or sequential per `lowMemoryMode`).
            let ollamaReady = ollamaClient != nil
            let activeMode = mode
            let systemPrompt = activeMode.systemPrompt(translateTarget: translateTarget)
            // Whether post-processing is requested. Actual server availability is checked at
            // call time in runLLM (the llama-server may be loaded lazily mid-pipeline in
            // low-RAM mode, so a captured ready-flag would be stale).
            let wantsLLM = activeMode != .off && systemPrompt != nil
            let filterLanguage = expectedLanguage
            // Script-mismatch guards only apply when LLM should preserve the source language.
            // For .translate the output language is intentionally different — disable the guard.
            let targetLang = activeMode == .translate ? nil : expectedLanguage
            log("Pipeline: concurrency=\(concurrency), lowMem=\(lowMemoryMode), mode=\(activeMode.rawValue), useLLM=\(wantsLLM), expected=\(expectedLanguage ?? "auto")", tag: "FileTranscription")

            // Per-chunk ASR step. Returns raw text (after replacements) or empty on failure.
            // Timeout: 2× realtime on healthy systems, 4× on low-RAM (slower without
            // flash-attention + watchdog needs headroom before declaring server hung).
            let timeoutMultiplier: TimeInterval = self.lowMemoryMode ? 4 : 2
            @Sendable func runASR(chunk: AudioConverter.AudioChunk) async -> String {
                do {
                    let timeout = max(60, chunk.duration * timeoutMultiplier)
                    var text = try await transcriber.transcribe(
                        audioURL: chunk.url,
                        timeout: timeout
                    )

                    if let expected = targetLang,
                       !text.isEmpty,
                       !Transcriber.scriptMatches(text, language: expected) {
                        let preview = String(text.prefix(60))
                        log("Chunk \(chunk.index): ASR script mismatch — '\(preview)'. Re-transcribing with \(expected) forced.", tag: "FileTranscription")
                        do {
                            let retry = try await transcriber.transcribe(
                                audioURL: chunk.url,
                                timeout: timeout,
                                languageOverride: expected
                            )
                            if !retry.isEmpty && Transcriber.scriptMatches(retry, language: expected) {
                                text = retry
                            } else {
                                log("Chunk \(chunk.index): still mismatch after forced '\(expected)' — dropping", tag: "FileTranscription")
                                text = ""
                            }
                        } catch {
                            log("Re-transcribe failed for chunk \(chunk.index), dropping", tag: "FileTranscription")
                            text = ""
                        }
                    }

                    text = text.stripCombiningAccents()
                    text = Transcriber.stripForeignChars(text, language: filterLanguage)
                    return TextReplacer.apply(text, replacements: self.replacements)
                } catch {
                    log("ASR failed for chunk \(chunk.index): \(error)", tag: "FileTranscription")
                    return ""
                }
            }

            // Per-chunk LLM step. Returns processed text, or raw on any failure / hallucination guard hit.
            // Server availability is checked live (not captured) so this works whether the LLM
            // was loaded eagerly up front or lazily after the ASR phase in low-RAM mode.
            @Sendable func runLLM(raw: String, chunkIndex: Int) async -> String {
                guard wantsLLM, !raw.isEmpty, let prompt = systemPrompt else { return raw }
                do {
                    let processed: String
                    if self.llamaClient?.isServerRunning == true, let llamaClient = self.llamaClient {
                        processed = try await llamaClient.process(text: raw, systemPrompt: prompt)
                    } else if let ollamaClient = self.ollamaClient {
                        processed = try await ollamaClient.process(text: raw, systemPrompt: prompt)
                    } else {
                        return raw
                    }
                    if activeMode != .translate && processed.count > raw.count * 3 {
                        log("LLM output too long for chunk \(chunkIndex) — using raw", tag: "FileTranscription")
                        return raw
                    }
                    if let expected = targetLang,
                       !Transcriber.scriptMatches(processed, language: expected),
                       Transcriber.scriptMatches(raw, language: expected) {
                        let preview = String(processed.prefix(60))
                        log("Chunk \(chunkIndex): LLM changed script — '\(preview)'. Using raw.", tag: "FileTranscription")
                        return raw
                    }
                    return processed
                } catch {
                    log("LLM failed for chunk \(chunkIndex): \(error). Using raw.", tag: "FileTranscription")
                    return raw
                }
            }

            if lowMemoryMode {
                // Sequential 2-phase, with the LLM loaded ONLY between the phases:
                //   Phase 1: all ASR  (whisper-server is the only model resident in RAM)
                //   → load llama-server →
                //   Phase 2: all post-processing
                // The llama working set (~2.5 GB) is never resident during the whisper ASR
                // pass. Loading it up front (as the non-low-RAM path does) overlaps the two
                // working sets on ≤8 GB machines → swap thrash → whisper/llama timeouts.
                //
                // Phase 1 streams raw ASR text into the window (so the user sees content
                // immediately, not an empty box for an hour). Phase 2 updates each chunk
                // in place with the LLM-processed text.
                var rawByIndex: [Int: String] = [:]
                let phaseLabel = wantsLLM ? "1/2" : "1/1"
                window.setStatus("Phase \(phaseLabel): transcribing...")
                for (i, chunk) in chunks.enumerated() {
                    let raw = await runASR(chunk: chunk)
                    rawByIndex[chunk.index] = raw
                    // Stream raw text right away — visible to the user before LLM phase
                    let result = ChunkResult(
                        index: chunk.index, startTime: chunk.startTime,
                        endTime: chunk.endTime, text: raw
                    )
                    window.appendChunk(result)
                    window.setStatus("Phase \(phaseLabel): transcribing \(i + 1)/\(totalChunks)...")
                }

                // Phase 1 done — now (and only now) bring up the LLM, so its working set
                // never coexisted with the whisper ASR pass.
                if wantsLLM, let onNeeded = onLLMNeeded {
                    window.setStatus("Loading post-processing model...")
                    let ready = await onNeeded()
                    if !ready {
                        log("LLM unavailable — files will use raw Whisper output", tag: "FileTranscription")
                    }
                }

                let llmAvailable = wantsLLM
                    && (self.llamaClient?.isServerRunning == true || ollamaReady)
                if llmAvailable {
                    // Reset progress bar for phase 2; chunks stay populated with raw text
                    // until each one is replaced by the LLM-processed version below.
                    window.beginPhase(label: "Phase 2/2: post-processing 0/\(totalChunks)...", totalChunks: totalChunks)
                    for (i, chunk) in chunks.enumerated() {
                        let raw = rawByIndex[chunk.index] ?? ""
                        let finalText = raw.isEmpty ? "" : await runLLM(raw: raw, chunkIndex: chunk.index)
                        window.updateChunkText(index: chunk.index, text: finalText)
                        window.tickPhaseProgress()
                        window.setStatus("Phase 2/2: post-processing \(i + 1)/\(totalChunks)...")
                    }
                }
            } else {
                // Pipelined: up to `concurrency` ASR and LLM requests in flight,
                // LLM runs in parallel with the next ASR.
                let asrSem = AsyncSemaphore(value: concurrency)
                let llmSem = AsyncSemaphore(value: concurrency)
                let completed = ChunkCounter()

                await withTaskGroup(of: Void.self) { group in
                    for chunk in chunks {
                        group.addTask {
                            await asrSem.wait()
                            let raw = await runASR(chunk: chunk)
                            await asrSem.signal()

                            await llmSem.wait()
                            let finalText = await runLLM(raw: raw, chunkIndex: chunk.index)
                            await llmSem.signal()

                            let result = ChunkResult(
                                index: chunk.index,
                                startTime: chunk.startTime,
                                endTime: chunk.endTime,
                                text: finalText
                            )
                            window.appendChunk(result)
                            let done = await completed.increment()
                            window.setStatus("Transcribing chunks... \(done)/\(totalChunks)")
                        }
                    }
                    await group.waitForAll()
                }
            }

            let totalTime = Date().timeIntervalSince(pipelineStart)
            window.finishStreaming(totalTime: totalTime)
            // Diagnostic: count empty chunks and find their range.
            // Trailing empties usually mean genuine silence or whisper-server failure mid-pipeline.
            let emptyChunks = window.emptyChunkIndices()
            if !emptyChunks.isEmpty {
                let first = emptyChunks.first!
                let last = emptyChunks.last!
                log("Transcription done in \(String(format: "%.1f", totalTime))s — \(emptyChunks.count)/\(totalChunks) chunks empty (indices \(first)…\(last))", tag: "FileTranscription")
            } else {
                log("Transcription done in \(String(format: "%.1f", totalTime))s", tag: "FileTranscription")
            }

            // Release lazy-loaded LLM (no-op if eagerly loaded for dictation)
            await onLLMRelease?()

        } catch {
            log("File transcription failed: \(error)", tag: "FileTranscription")
            window.setError("Error: \(error.localizedDescription)")
            // Release on error too
            await onLLMRelease?()
        }
    }
}
