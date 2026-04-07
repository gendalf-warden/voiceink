import AppKit
import Foundation
import UniformTypeIdentifiers

/// Orchestrates file transcription: file picker → convert → transcribe → LLM post-process → show result
public class FileTranscriptionManager {
    private var resultWindow: TranscriptionResultWindowController?
    private let converter = AudioConverter()
    public var llamaClient: LlamaClient?
    public var ollamaClient: OllamaClient?
    public var punctuationEnabled: Bool = true

    public init() {}

    public func startFileTranscription(transcriber: Transcriber) {
        // Show file picker
        let panel = NSOpenPanel()
        panel.title = "Select audio or video file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        // Supported file types
        var types: [UTType] = []
        for ext in AudioConverter.supportedExtensions {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            return // User cancelled
        }

        log("File transcription: \(fileURL.lastPathComponent)", tag: "FileTranscription")

        // Show result window with spinner
        let result = TranscriptionResultWindowController()
        result.show()
        result.setStatus("Opening \(fileURL.lastPathComponent)...")
        self.resultWindow = result

        // Run pipeline in background
        Task {
            do {
                // Step 1: Get duration for timeout estimation
                let duration = await converter.duration(fileURL: fileURL)
                let durationStr = duration > 0 ? String(format: "%.0f", duration) + "s" : "unknown"
                log("File duration: \(durationStr)", tag: "FileTranscription")

                // Step 2: Convert to 16kHz mono WAV
                result.setStatus("Converting audio (\(durationStr))...")
                let convertStart = Date()
                let wavURL = try await converter.convert(fileURL: fileURL)
                let convertTime = Date().timeIntervalSince(convertStart)
                log("Conversion took \(String(format: "%.1f", convertTime))s", tag: "FileTranscription")

                defer { try? FileManager.default.removeItem(at: wavURL) }

                // Step 3: Transcribe
                // Timeout: at least 60s, or 2x the audio duration (whisper is ~10x realtime on GPU)
                let timeout = max(60, duration * 2)
                result.setStatus("Transcribing (\(durationStr) audio)...")
                let asrStart = Date()
                let text = try await transcriber.transcribe(audioURL: wavURL, timeout: timeout)
                    .stripCombiningAccents()
                let asrTime = Date().timeIntervalSince(asrStart)

                let wordCount = text.split(separator: " ").count
                log("Transcription done: \(wordCount) words in \(String(format: "%.1f", asrTime))s", tag: "FileTranscription")

                // Step 4: Post-process with LLM (same logic as voice dictation)
                var finalText = text
                let llamaReady = llamaClient?.isServerRunning == true
                let ollamaReady = ollamaClient != nil
                if punctuationEnabled && (llamaReady || ollamaReady) && !text.isEmpty {
                    result.setStatus("Improving punctuation...")
                    do {
                        let llmStart = Date()
                        if llamaReady, let llamaClient = llamaClient {
                            finalText = try await llamaClient.postProcess(text: text)
                        } else if let ollamaClient = ollamaClient {
                            finalText = try await ollamaClient.postProcess(text: text)
                        }
                        let llmTime = Date().timeIntervalSince(llmStart)
                        log("LLM post-process took \(String(format: "%.1f", llmTime))s", tag: "FileTranscription")
                    } catch {
                        log("LLM post-process failed: \(error). Using raw text.", tag: "FileTranscription")
                    }
                }

                // Step 5: Show result
                result.setResult(finalText)

            } catch {
                log("File transcription failed: \(error)", tag: "FileTranscription")
                result.setError("Error: \(error.localizedDescription)")
            }
        }
    }
}
