import AVFoundation
import Foundation

/// Converts audio/video files to 16kHz mono 16-bit PCM WAV for whisper-server
public class AudioConverter {

    public static let supportedExtensions = ["mp3", "wav", "m4a", "mp4", "mov", "aac", "flac", "ogg"]

    /// Convert any supported audio/video file to 16kHz mono WAV
    /// Returns URL of temporary WAV file (caller is responsible for cleanup)
    public func convert(fileURL: URL) async throws -> URL {
        let asset = AVAsset(url: fileURL)

        // Check that file has an audio track
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioConverterError.noAudioTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-convert-\(UUID().uuidString).wav")

        // Output settings: 16kHz mono 16-bit PCM (whisper requirement)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        // Set up reader
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw AudioConverterError.conversionFailed("Cannot read audio track")
        }
        reader.add(readerOutput)

        // Set up writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        guard writer.canAdd(writerInput) else {
            throw AudioConverterError.conversionFailed("Cannot create WAV writer")
        }
        writer.add(writerInput)

        // Start processing
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Process samples on a background queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.voiceink.audioconverter")
            // AVFoundation objects aren't Sendable, but this callback is invoked serially
            // on `queue`, so the captures are safe. Rebind as nonisolated(unsafe) to
            // silence #SendableClosureCaptures without changing the (correct) behavior.
            nonisolated(unsafe) let writerInput = writerInput
            nonisolated(unsafe) let readerOutput = readerOutput
            nonisolated(unsafe) let reader = reader
            nonisolated(unsafe) let writer = writer
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()

                        if reader.status == .failed {
                            writer.cancelWriting()
                            continuation.resume(throwing: AudioConverterError.conversionFailed(
                                reader.error?.localizedDescription ?? "Unknown read error"))
                            return
                        }

                        writer.finishWriting {
                            if writer.status == .failed {
                                continuation.resume(throwing: AudioConverterError.conversionFailed(
                                    writer.error?.localizedDescription ?? "Unknown write error"))
                            } else {
                                continuation.resume()
                            }
                        }
                        return
                    }
                }
            }
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        let sizeMB = String(format: "%.1f", Double(fileSize) / 1_000_000)
        log("Converted \(fileURL.lastPathComponent) -> \(sizeMB) MB WAV", tag: "AudioConverter")

        return outputURL
    }

    /// Estimate audio duration from file
    public func duration(fileURL: URL) async -> TimeInterval {
        let asset = AVAsset(url: fileURL)
        let duration = try? await asset.load(.duration)
        return duration?.seconds ?? 0
    }

    /// A chunk of audio with its position in the original file
    public struct AudioChunk {
        public let url: URL
        public let startTime: TimeInterval  // seconds from start of original
        public let endTime: TimeInterval
        public var duration: TimeInterval { endTime - startTime }
        public var index: Int
    }

    /// Split a 16kHz mono WAV into chunks of ~targetDuration seconds.
    /// Finds silence in a ±searchWindow around each boundary to avoid cutting words.
    /// Returns URLs of temp WAV files (caller is responsible for cleanup).
    ///
    /// Streaming implementation: reads one window of (target + searchWindow) frames at a time
    /// using `file.framePosition` seeks. Peak memory is ~(target + searchWindow) * 4 bytes ≈
    /// 2.2 MB for 35s @ 16kHz float32, regardless of total file length. The previous in-memory
    /// approach allocated ~553 MB for a 2.5h file, which broke on RAM-constrained machines
    /// (truncated buffer → silent chunks → empty transcription for the second half).
    public func splitIntoChunks(
        wavURL: URL,
        targetDuration: TimeInterval = 30.0,
        searchWindow: TimeInterval = 5.0
    ) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: wavURL)
        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = Int(file.length)
        let totalDuration = Double(totalFrames) / sampleRate

        // If file is shorter than one chunk, return as-is
        if totalDuration <= targetDuration * 1.5 {
            return [AudioChunk(url: wavURL, startTime: 0, endTime: totalDuration, index: 0)]
        }

        let targetSamples = Int(targetDuration * sampleRate)
        let windowSamples = Int(searchWindow * sampleRate)
        let silenceThreshold: Float = 0.005
        let minSilenceRun = Int(sampleRate * 0.2) // 200ms of silence
        let format = file.processingFormat
        let settings = file.fileFormat.settings

        var chunks: [AudioChunk] = []
        var currentStart = 0  // absolute frame position in the file
        var chunkIndex = 0

        while currentStart < totalFrames {
            // Read up to (target + window) frames starting at currentStart.
            // The extra `window` frames are forward-lookahead for silence search.
            let remaining = totalFrames - currentStart
            let readSize = min(targetSamples + windowSamples, remaining)

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(readSize)
            ) else {
                throw AudioConverterError.conversionFailed("Cannot allocate \(readSize)-frame buffer")
            }

            file.framePosition = AVAudioFramePosition(currentStart)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(readSize))
            let loaded = Int(buffer.frameLength)

            // If even one window's worth couldn't be loaded, bail with a clear warning.
            // Continuing would produce a single silent chunk for the rest of the file.
            if loaded == 0 {
                log("WARNING: read returned 0 frames at position \(currentStart)/\(totalFrames). Stopping split early.", tag: "AudioConverter")
                break
            }
            if loaded < readSize && currentStart + loaded < totalFrames {
                log("WARNING: read returned \(loaded)/\(readSize) frames at position \(currentStart). Truncating remaining file.", tag: "AudioConverter")
            }

            guard let samples = buffer.floatChannelData?[0] else {
                throw AudioConverterError.conversionFailed("Cannot access samples")
            }

            // Decide cut offset within the buffer (relative to currentStart).
            let cutOffset: Int
            if loaded < targetSamples + windowSamples / 2 {
                // Near end of file (or short read): take the whole loaded range as the final chunk.
                cutOffset = loaded
            } else {
                // Search silence in [target - window, target + window] of the buffer.
                let searchStart = max(0, targetSamples - windowSamples)
                let searchEnd = min(loaded, targetSamples + windowSamples)
                cutOffset = findSilenceCenter(
                    samples: samples,
                    from: searchStart,
                    to: searchEnd,
                    threshold: silenceThreshold,
                    minRun: minSilenceRun
                ) ?? targetSamples
            }

            // Sanity: never advance by 0, would infinite-loop.
            guard cutOffset > 0 else {
                log("WARNING: cutOffset == 0 at position \(currentStart). Stopping split.", tag: "AudioConverter")
                break
            }

            // Write chunk [0..cutOffset] of buffer to a temp WAV.
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceink-chunk-\(chunkIndex)-\(UUID().uuidString).wav")

            guard let chunkBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(cutOffset)
            ) else {
                throw AudioConverterError.conversionFailed("Cannot allocate chunk buffer")
            }
            memcpy(
                chunkBuffer.floatChannelData![0],
                samples,
                cutOffset * MemoryLayout<Float>.size
            )
            chunkBuffer.frameLength = AVAudioFrameCount(cutOffset)

            let writer = try AVAudioFile(forWriting: chunkURL, settings: settings)
            try writer.write(from: chunkBuffer)

            let startTime = Double(currentStart) / sampleRate
            let endTime = Double(currentStart + cutOffset) / sampleRate
            chunks.append(AudioChunk(
                url: chunkURL,
                startTime: startTime,
                endTime: endTime,
                index: chunkIndex
            ))

            currentStart += cutOffset
            chunkIndex += 1
        }

        log("Split into \(chunks.count) chunks (total \(String(format: "%.1f", totalDuration))s, streaming)", tag: "AudioConverter")
        return chunks
    }

    /// Find the center of the longest silence run within [from, to).
    /// Returns nil if no silence found.
    private func findSilenceCenter(
        samples: UnsafePointer<Float>,
        from: Int,
        to: Int,
        threshold: Float,
        minRun: Int
    ) -> Int? {
        var bestRunStart = -1
        var bestRunEnd = -1
        var currentRunStart = -1

        for i in from..<to {
            if abs(samples[i]) <= threshold {
                if currentRunStart == -1 {
                    currentRunStart = i
                }
            } else {
                if currentRunStart != -1 {
                    let runLen = i - currentRunStart
                    let bestLen = bestRunEnd - bestRunStart
                    if runLen >= minRun && runLen > bestLen {
                        bestRunStart = currentRunStart
                        bestRunEnd = i
                    }
                    currentRunStart = -1
                }
            }
        }
        // Tail
        if currentRunStart != -1 {
            let runLen = to - currentRunStart
            let bestLen = bestRunEnd - bestRunStart
            if runLen >= minRun && runLen > bestLen {
                bestRunStart = currentRunStart
                bestRunEnd = to
            }
        }

        guard bestRunStart != -1 else { return nil }
        return (bestRunStart + bestRunEnd) / 2
    }

    public enum AudioConverterError: Error, LocalizedError {
        case noAudioTrack
        case conversionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "File has no audio track"
            case .conversionFailed(let msg): return "Audio conversion failed: \(msg)"
            }
        }
    }
}
