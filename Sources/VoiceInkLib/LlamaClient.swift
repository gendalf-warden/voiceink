import Foundation

/// Manages a bundled llama-server subprocess for LLM punctuation (replaces Ollama dependency)
public class LlamaClient {
    private let serverPath: String
    private let modelPath: String
    private let port = 8179
    private let host = "127.0.0.1"
    private var serverProcess: Process?
    public private(set) var isServerRunning = false

    public init(serverPath: String, modelPath: String) {
        self.serverPath = serverPath
        self.modelPath = modelPath
    }

    public func startServer() throws {
        guard FileManager.default.isExecutableFile(atPath: serverPath) else {
            throw LlamaError.serverNotFound(serverPath)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LlamaError.modelNotFound(modelPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.arguments = [
            "-m", modelPath,
            "--host", host,
            "--port", String(port),
            "-ngl", "99",        // offload all layers to GPU
            "-t", "4",
        ]
        // ggml backend plugins (.so) are in lib-llama/ next to llama-server
        let serverDir = (serverPath as NSString).deletingLastPathComponent
        let backendPath = (serverDir as NSString).appendingPathComponent("lib-llama")
        var env = ProcessInfo.processInfo.environment
        env["GGML_BACKEND_PATH"] = backendPath
        process.environment = env

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        serverProcess = process
        log("LLM server starting on \(host):\(port)...", tag: "Llama")
        log("LLM server path: \(serverPath)", tag: "Llama")
        log("LLM model path: \(modelPath)", tag: "Llama")

        // On low-memory systems give more time for model loading
        let maxAttempts = Config.systemRAMGB < 16 ? 120 : 60  // 60s or 30s
        isServerRunning = waitForServer(maxAttempts: maxAttempts)

        if !isServerRunning {
            // Log stderr to help diagnose
            let stderrData = stderrPipe.fileHandleForReading.availableData
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            if !stderrStr.isEmpty {
                let lastLines = stderrStr.components(separatedBy: "\n").suffix(10).joined(separator: "\n")
                log("LLM server stderr:\n\(lastLines)", tag: "Llama")
            }

            // Server didn't become ready — check if process crashed
            if !process.isRunning {
                log("LLM server process crashed (exit code: \(process.terminationStatus))", tag: "Llama")
                serverProcess = nil
            }
            throw LlamaError.serverStartTimeout
        }
    }

    public func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
        isServerRunning = false
        log("LLM server stopped", tag: "Llama")
    }

    public func postProcess(text: String) async throws -> String {
        let systemPrompt = """
        Fix punctuation and capitalization in this speech-to-text output. Rules:
        - Add missing periods, commas, question marks, exclamation marks
        - Fix capitalization at sentence starts and proper nouns
        - Keep numbers as digits (do NOT spell them out)
        - Do NOT rephrase, do NOT change words, do NOT translate
        - Preserve the original language (Russian, English, or mixed)
        - Output ONLY the corrected text, nothing else
        """

        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "stream": false,
            "temperature": 0.1,
            "max_tokens": 2048,
        ]

        let (data, response) = try await post(path: "/v1/chat/completions", body: body, timeout: 30)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LlamaError.requestFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let result = message["content"] as? String else {
            throw LlamaError.invalidResponse
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func warmup() async {
        guard isServerRunning else {
            log("Skipping warmup — server not running", tag: "Llama")
            return
        }
        let body: [String: Any] = [
            "messages": [["role": "user", "content": "Hello"]],
            "stream": false,
            "max_tokens": 1,
        ]
        do {
            _ = try await post(path: "/v1/chat/completions", body: body, timeout: 60)
            log("LLM model warmed up", tag: "Llama")
        } catch {
            log("LLM warmup failed: \(error.localizedDescription)", tag: "Llama")
            isServerRunning = false
        }
    }

    // MARK: - Private

    private func post(path: String, body: [String: Any], timeout: TimeInterval) async throws -> (Data, URLResponse) {
        let url = URL(string: "http://\(host):\(port)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        return try await URLSession.shared.data(for: request)
    }

    @discardableResult
    private func waitForServer(maxAttempts: Int = 60) -> Bool {
        let url = URL(string: "http://\(host):\(port)/health")!
        for i in 1...maxAttempts {
            Thread.sleep(forTimeInterval: 0.5)

            // Check if process crashed before polling
            if let proc = serverProcess, !proc.isRunning {
                log("LLM server process died during startup (exit code: \(proc.terminationStatus))", tag: "Llama")
                return false
            }

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
                log("LLM server ready (took \(String(format: "%.1f", Double(i) * 0.5))s)", tag: "Llama")
                return true
            }
        }
        log("LLM server did not become ready in time (\(maxAttempts / 2)s)", tag: "Llama")
        return false
    }

    public enum LlamaError: Error, LocalizedError {
        case serverNotFound(String)
        case modelNotFound(String)
        case serverStartTimeout
        case requestFailed
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .serverNotFound(let path): return "llama-server not found at: \(path)"
            case .modelNotFound(let path): return "LLM model not found at: \(path)"
            case .serverStartTimeout: return "LLM server did not become ready in time"
            case .requestFailed: return "LLM request failed"
            case .invalidResponse: return "Invalid response from LLM server"
            }
        }
    }
}
