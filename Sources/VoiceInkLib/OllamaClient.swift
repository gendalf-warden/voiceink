import Foundation

public class OllamaClient: LLMProcessor {
    private let endpoint: String
    private let model: String

    public init(endpoint: String, model: String) {
        self.endpoint = endpoint
        self.model = model
    }

    /// Run the LLM with the given system prompt on `text`. Returns trimmed output.
    /// The system prompt comes from `PostProcessingMode.systemPrompt(...)`.
    /// Ollama's /api/generate has no separate system role — we embed both in `prompt`.
    public func process(text: String, systemPrompt: String) async throws -> String {
        let prompt = """
        \(systemPrompt)

        TEXT: \(text)
        OUTPUT:
        """

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1,
                "num_predict": 2048,
            ],
        ]

        let (data, response) = try await post(path: "/api/generate", body: body, timeout: 30)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OllamaError.requestFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["response"] as? String else {
            throw OllamaError.invalidResponse
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Load model into memory so the first real request is fast
    public func warmup() async {
        let body: [String: Any] = [
            "model": model,
            "prompt": "Hello",
            "stream": false,
            "options": ["num_predict": 1],
        ]
        _ = try? await post(path: "/api/generate", body: body, timeout: 60)
        log("Model \(model) warmed up", tag: "Ollama")
    }

    /// Unload model from memory (free VRAM)
    public func unloadModel() async {
        let body: [String: Any] = [
            "model": model,
            "keep_alive": 0,
        ]
        _ = try? await post(path: "/api/generate", body: body, timeout: 10)
        log("Model \(model) unloaded", tag: "Ollama")
    }

    public func isAvailable() async -> Bool {
        guard let url = URL(string: "\(endpoint)/api/tags") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Private

    private func post(path: String, body: [String: Any], timeout: TimeInterval) async throws -> (Data, URLResponse) {
        let url = URL(string: "\(endpoint)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        return try await URLSession.shared.data(for: request)
    }

    public enum OllamaError: Error, LocalizedError {
        case requestFailed
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .requestFailed: return "Ollama request failed. Is Ollama running?"
            case .invalidResponse: return "Invalid response from Ollama"
            }
        }
    }
}
