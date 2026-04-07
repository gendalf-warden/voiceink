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

    public func transcribe(audioURL: URL, timeout: TimeInterval = 30) async throws -> String {
        let url = URL(string: "http://\(serverHost):\(serverPort)/inference")!
        let audioData = try Data(contentsOf: audioURL)

        // Build multipart form data
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
        body.append("text\r\n".data(using: .utf8)!)

        // Send language per-request (matches server default, but explicit is safer)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(config.language)\r\n".data(using: .utf8)!)

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

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
