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
    public var llamaClient: LlamaClient?
    public var ollamaClient: OllamaClient?
    public var punctuationEnabled: Bool = true
    /// Number of concurrent ASR/LLM requests (2 = ~60% faster than sequential baseline)
    public var concurrency: Int = 2

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
        // Show file picker
        let panel = NSOpenPanel()
        panel.title = "Select audio or video file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        var types: [UTType] = []
        for ext in AudioConverter.supportedExtensions {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK, let fileURL = panel.url else {
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

            // Step 4b: Parallel pipeline — up to `concurrency` ASR and LLM requests in flight
            let llamaReady = llamaClient?.isServerRunning == true
            let ollamaReady = ollamaClient != nil
            let useLLM = punctuationEnabled && (llamaReady || ollamaReady)
            let asrSem = AsyncSemaphore(value: concurrency)
            let llmSem = AsyncSemaphore(value: concurrency)
            let completed = ChunkCounter()
            let filterLanguage = expectedLanguage
            let targetLang = expectedLanguage
            log("Pipeline: concurrency=\(concurrency), useLLM=\(useLLM), expected=\(expectedLanguage ?? "auto")", tag: "FileTranscription")

            await withTaskGroup(of: Void.self) { group in
                for chunk in chunks {
                    group.addTask { [weak self] in
                        guard let self = self else { return }

                        // ASR with fast text format. After transcription, check if the output's
                        // script matches expected language (cheap character analysis, no extra server call).
                        // If not — re-transcribe with expected language forced to reject hallucinations.
                        await asrSem.wait()
                        let raw: String
                        do {
                            let timeout = max(60, chunk.duration * 2)
                            var text = try await transcriber.transcribe(
                                audioURL: chunk.url,
                                timeout: timeout
                            )

                            // Script mismatch check (no extra HTTP call — pure char analysis)
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
                                    // If still mismatched after forced language, the audio is likely noise
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
                            raw = Transcriber.stripForeignChars(text, language: filterLanguage)
                        } catch {
                            await asrSem.signal()
                            log("ASR failed for chunk \(chunk.index): \(error)", tag: "FileTranscription")
                            let result = ChunkResult(index: chunk.index, startTime: chunk.startTime,
                                                     endTime: chunk.endTime, text: "")
                            window.appendChunk(result)
                            let done = await completed.increment()
                            window.setStatus("Transcribing chunks... \(done)/\(totalChunks)")
                            return
                        }
                        await asrSem.signal()

                        // LLM (pipelined — runs while next ASR is already in flight)
                        var finalText = raw
                        if useLLM && !raw.isEmpty {
                            await llmSem.wait()
                            do {
                                let processed: String
                                if llamaReady, let llamaClient = self.llamaClient {
                                    processed = try await llamaClient.postProcess(text: raw)
                                } else if let ollamaClient = self.ollamaClient {
                                    processed = try await ollamaClient.postProcess(text: raw)
                                } else {
                                    processed = raw
                                }
                                // Hallucination guard: length
                                if processed.count > raw.count * 3 {
                                    log("LLM output too long for chunk \(chunk.index) — using raw", tag: "FileTranscription")
                                    finalText = raw
                                }
                                // Hallucination guard: translation (LLM ignored "do not translate" rule)
                                else if let expected = targetLang,
                                        !Transcriber.scriptMatches(processed, language: expected),
                                        Transcriber.scriptMatches(raw, language: expected) {
                                    let preview = String(processed.prefix(60))
                                    log("Chunk \(chunk.index): LLM changed script — '\(preview)'. Using raw.", tag: "FileTranscription")
                                    finalText = raw
                                } else {
                                    finalText = processed
                                }
                            } catch {
                                log("LLM failed for chunk \(chunk.index): \(error). Using raw.", tag: "FileTranscription")
                                finalText = raw
                            }
                            await llmSem.signal()
                        }

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

            let totalTime = Date().timeIntervalSince(pipelineStart)
            window.finishStreaming(totalTime: totalTime)
            log("Transcription done in \(String(format: "%.1f", totalTime))s", tag: "FileTranscription")

        } catch {
            log("File transcription failed: \(error)", tag: "FileTranscription")
            window.setError("Error: \(error.localizedDescription)")
        }
    }
}
