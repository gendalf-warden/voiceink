import AVFoundation
import Foundation

public class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    public init() {}

    public func startRecording() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("voiceink-\(UUID().uuidString).wav")
        tempFileURL = fileURL

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        audioFile = try AVAudioFile(forWriting: fileURL, settings: fileSettings)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecorderError.converterFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * self.outputFormat.sampleRate / inputFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil {
                try? audioFile.write(from: convertedBuffer)
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine

        return fileURL
    }

    public func stopRecording() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        // Trim trailing silence to prevent Whisper hallucinations
        if let url = tempFileURL {
            trimTrailingSilence(url: url)
        }

        return tempFileURL
    }

    /// Remove trailing silence from WAV file to prevent Whisper from hallucinating
    /// on quiet endings (e.g. adding "Продолжение следует..." or "Thank you.")
    private func trimTrailingSilence(url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return }

        let sampleRate = file.processingFormat.sampleRate
        // Read the whole file into a buffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: totalFrames) else { return }
        do { try file.read(into: buffer) } catch { return }

        guard let channelData = buffer.floatChannelData?[0] else { return }

        // Walk backwards from the end, find the last sample above threshold
        let silenceThreshold: Float = 0.005
        let chunkSize = Int(sampleRate * 0.05) // 50ms chunks
        var lastLoudFrame = Int(totalFrames)

        for i in stride(from: Int(totalFrames) - chunkSize, through: 0, by: -chunkSize) {
            let end = min(i + chunkSize, Int(totalFrames))
            var maxAmp: Float = 0
            for j in i..<end {
                let amp = abs(channelData[j])
                if amp > maxAmp { maxAmp = amp }
            }
            if maxAmp > silenceThreshold {
                // Keep 200ms of silence after last loud chunk for natural ending
                lastLoudFrame = min(end + Int(sampleRate * 0.2), Int(totalFrames))
                break
            }
        }

        // Only trim if we'd remove at least 500ms of silence
        let trimmedFrames = Int(totalFrames) - lastLoudFrame
        let minTrimFrames = Int(sampleRate * 0.5)
        guard trimmedFrames >= minTrimFrames else { return }

        // Write trimmed audio to the same file
        let settings = file.fileFormat.settings
        guard let trimmedBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(lastLoudFrame)) else { return }
        memcpy(trimmedBuffer.floatChannelData![0], channelData, lastLoudFrame * MemoryLayout<Float>.size)
        trimmedBuffer.frameLength = AVAudioFrameCount(lastLoudFrame)

        do {
            let writer = try AVAudioFile(forWriting: url, settings: settings)
            try writer.write(from: trimmedBuffer)
            let trimmedMs = Int(Double(trimmedFrames) / sampleRate * 1000)
            log("Trimmed \(trimmedMs)ms trailing silence", tag: "AudioRecorder")
        } catch {
            log("Failed to trim silence: \(error)", tag: "AudioRecorder")
        }
    }

    /// Peak amplitude across the whole recording (0…1). Returns -1 if unreadable.
    /// Used both for the silence gate and for diagnostic logging.
    public static func peakAmplitude(url: URL) -> Float {
        guard let file = try? AVAudioFile(forReading: url) else { return -1 }
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return 0 }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: totalFrames) else { return -1 }
        do { try file.read(into: buffer) } catch { return -1 }
        guard let channelData = buffer.floatChannelData?[0] else { return -1 }

        var peak: Float = 0
        for i in 0..<Int(totalFrames) {
            let amp = abs(channelData[i])
            if amp > peak { peak = amp }
        }
        return peak
    }

    /// Speech-floor for the silence gate: peaks below this are room tone / silence.
    /// Well below normal speech peaks (~0.1–0.9) but above ambient noise.
    public static let speechFloor: Float = 0.01

    /// True when the recording carries no real speech — its peak amplitude across the
    /// whole file stays below the speech floor. Recording silence and feeding it to
    /// Whisper produces phantom phrases ("Thank you.", "Продолжение следует…") that get
    /// pasted into whatever the user is typing. We drop such clips before transcription.
    public static func isSilent(url: URL) -> Bool {
        let peak = peakAmplitude(url: url)
        guard peak >= 0 else { return false }   // unreadable → don't drop
        return peak < speechFloor
    }

    public static func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    enum RecorderError: Error {
        case converterFailed
    }
}
