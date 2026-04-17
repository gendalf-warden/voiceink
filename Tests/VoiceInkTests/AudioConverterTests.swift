import XCTest
import AVFoundation
@testable import VoiceInkLib

final class AudioConverterTests: XCTestCase {

    // MARK: - Helpers

    /// Generate a 16kHz mono WAV with specified duration. Silence by default.
    /// Use `loudRanges` to mark [start, end) in seconds where samples = 0.5 amplitude.
    private func makeTestWAV(duration: TimeInterval, loudRanges: [(TimeInterval, TimeInterval)] = []) throws -> URL {
        let sampleRate: Double = 16000
        let totalFrames = Int(duration * sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-test-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw NSError(domain: "test", code: 0)
        }
        let samples = buffer.floatChannelData![0]
        for i in 0..<totalFrames {
            samples[i] = 0
        }
        for range in loudRanges {
            let start = Int(range.0 * sampleRate)
            let end = min(Int(range.1 * sampleRate), totalFrames)
            for i in start..<end {
                // Sine wave at 440Hz with 0.5 amplitude — well above silence threshold
                samples[i] = 0.5 * sin(2.0 * Float.pi * 440.0 * Float(i) / Float(sampleRate))
            }
        }
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        try file.write(from: buffer)
        return url
    }

    // MARK: - splitIntoChunks

    func testShortFileReturnsAsOneChunk() throws {
        let converter = AudioConverter()
        let url = try makeTestWAV(duration: 10, loudRanges: [(0, 10)])
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try converter.splitIntoChunks(wavURL: url, targetDuration: 30)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].url, url) // returns original
        XCTAssertEqual(chunks[0].startTime, 0)
        XCTAssertEqual(chunks[0].endTime, 10, accuracy: 0.1)
    }

    func testLongFileSplitsIntoMultipleChunks() throws {
        let converter = AudioConverter()
        // 90 seconds of continuous sound → should split into ~3 chunks of 30s
        let url = try makeTestWAV(duration: 90, loudRanges: [(0, 90)])
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try converter.splitIntoChunks(wavURL: url, targetDuration: 30)
        defer {
            for c in chunks where c.url != url {
                try? FileManager.default.removeItem(at: c.url)
            }
        }

        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertLessThanOrEqual(chunks.count, 4)
        // Chunks should cover the whole file contiguously
        XCTAssertEqual(chunks[0].startTime, 0, accuracy: 0.1)
        XCTAssertEqual(chunks.last!.endTime, 90, accuracy: 0.5)
        for i in 1..<chunks.count {
            XCTAssertEqual(chunks[i].startTime, chunks[i - 1].endTime, accuracy: 0.1)
        }
    }

    func testSplitPrefersSilenceBoundaries() throws {
        let converter = AudioConverter()
        // Sound 0-28s, silence 28-32s (4 seconds of silence), sound 32-60s
        // Target 30s with ±5s window → should split in the silence (28-32)
        let url = try makeTestWAV(duration: 60, loudRanges: [(0, 28), (32, 60)])
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try converter.splitIntoChunks(wavURL: url, targetDuration: 30, searchWindow: 5)
        defer {
            for c in chunks where c.url != url {
                try? FileManager.default.removeItem(at: c.url)
            }
        }

        XCTAssertEqual(chunks.count, 2)
        // Split point should be in [28, 32] (the silence region)
        XCTAssertGreaterThan(chunks[0].endTime, 28)
        XCTAssertLessThan(chunks[0].endTime, 32)
    }

    func testChunkIndicesAreSequential() throws {
        let converter = AudioConverter()
        let url = try makeTestWAV(duration: 120, loudRanges: [(0, 120)])
        defer { try? FileManager.default.removeItem(at: url) }

        let chunks = try converter.splitIntoChunks(wavURL: url, targetDuration: 30)
        defer {
            for c in chunks where c.url != url {
                try? FileManager.default.removeItem(at: c.url)
            }
        }

        for (i, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.index, i)
        }
    }
}
