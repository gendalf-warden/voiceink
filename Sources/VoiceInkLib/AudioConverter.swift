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
