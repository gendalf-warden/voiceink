import XCTest
@testable import VoiceInkLib

final class ConfigTests: XCTestCase {

    // MARK: - Codable round-trip

    func testEncodeDecodeRoundTrip() throws {
        let config = Config(
            whisperCliPath: "/usr/bin/whisper",
            whisperServerPath: "/usr/bin/whisper-server",
            whisperModelPath: "/models/ggml-large-v3-turbo-q5_0.bin",
            language: "ru",
            hotkeyKeyCode: 49,
            hotkeyModifiers: ["cmd", "shift"],
            llamaServerPath: "/usr/bin/llama-server",
            llamaModelPath: "/models/qwen2.5-3b.gguf",
            ollamaEnabled: false,
            ollamaModel: "qwen2.5:3b",
            ollamaEndpoint: "http://localhost:11434",
            launchAtLogin: true,
            logTranscriptions: false,
            punctuationEnabled: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)

        XCTAssertEqual(decoded.whisperCliPath, config.whisperCliPath)
        XCTAssertEqual(decoded.whisperServerPath, config.whisperServerPath)
        XCTAssertEqual(decoded.whisperModelPath, config.whisperModelPath)
        XCTAssertEqual(decoded.language, config.language)
        XCTAssertEqual(decoded.hotkeyKeyCode, config.hotkeyKeyCode)
        XCTAssertEqual(decoded.hotkeyModifiers, config.hotkeyModifiers)
        XCTAssertEqual(decoded.llamaServerPath, config.llamaServerPath)
        XCTAssertEqual(decoded.llamaModelPath, config.llamaModelPath)
        XCTAssertEqual(decoded.ollamaEnabled, config.ollamaEnabled)
        XCTAssertEqual(decoded.ollamaModel, config.ollamaModel)
        XCTAssertEqual(decoded.ollamaEndpoint, config.ollamaEndpoint)
        XCTAssertEqual(decoded.launchAtLogin, config.launchAtLogin)
        XCTAssertEqual(decoded.logTranscriptions, config.logTranscriptions)
        XCTAssertEqual(decoded.punctuationEnabled, config.punctuationEnabled)
    }

    // MARK: - Backward compatibility (missing optional fields)

    func testDecodeMissingOptionalFields() throws {
        // Minimal JSON — only required fields, optional ones missing
        let json = """
        {
            "whisperCliPath": "/usr/bin/whisper",
            "whisperModelPath": "/models/model.bin",
            "language": "auto",
            "hotkeyKeyCode": 63,
            "hotkeyModifiers": [],
            "ollamaEnabled": true,
            "ollamaModel": "qwen2.5:3b",
            "ollamaEndpoint": "http://localhost:11434"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(Config.self, from: json)

        // Optional fields should have defaults
        XCTAssertEqual(config.whisperServerPath, "")
        XCTAssertEqual(config.llamaServerPath, "")
        XCTAssertEqual(config.llamaModelPath, "")
        XCTAssertEqual(config.launchAtLogin, false)
        XCTAssertEqual(config.logTranscriptions, true)
        // punctuationEnabled defaults based on RAM — just check it decodes without crash
        _ = config.punctuationEnabled
    }

    // MARK: - llamaAvailable

    func testLlamaAvailableBothSet() {
        let config = Config(
            whisperCliPath: "", whisperServerPath: "", whisperModelPath: "",
            language: "auto", hotkeyKeyCode: 63, hotkeyModifiers: [],
            llamaServerPath: "/bin/llama", llamaModelPath: "/models/model.gguf",
            ollamaEnabled: true, ollamaModel: "", ollamaEndpoint: "",
            launchAtLogin: false, logTranscriptions: true, punctuationEnabled: true
        )
        XCTAssertTrue(config.llamaAvailable)
    }

    func testLlamaAvailableMissingServer() {
        let config = Config(
            whisperCliPath: "", whisperServerPath: "", whisperModelPath: "",
            language: "auto", hotkeyKeyCode: 63, hotkeyModifiers: [],
            llamaServerPath: "", llamaModelPath: "/models/model.gguf",
            ollamaEnabled: true, ollamaModel: "", ollamaEndpoint: "",
            launchAtLogin: false, logTranscriptions: true, punctuationEnabled: true
        )
        XCTAssertFalse(config.llamaAvailable)
    }

    func testLlamaAvailableMissingModel() {
        let config = Config(
            whisperCliPath: "", whisperServerPath: "", whisperModelPath: "",
            language: "auto", hotkeyKeyCode: 63, hotkeyModifiers: [],
            llamaServerPath: "/bin/llama", llamaModelPath: "",
            ollamaEnabled: true, ollamaModel: "", ollamaEndpoint: "",
            launchAtLogin: false, logTranscriptions: true, punctuationEnabled: true
        )
        XCTAssertFalse(config.llamaAvailable)
    }

    // MARK: - whisperModelName

    func testWhisperModelName() {
        let config = Config(
            whisperCliPath: "", whisperServerPath: "", whisperModelPath: "/path/to/ggml-large-v3-turbo-q5_0.bin",
            language: "auto", hotkeyKeyCode: 63, hotkeyModifiers: [],
            llamaServerPath: "", llamaModelPath: "",
            ollamaEnabled: true, ollamaModel: "", ollamaEndpoint: "",
            launchAtLogin: false, logTranscriptions: true, punctuationEnabled: true
        )
        XCTAssertEqual(config.whisperModelName, "large-v3-turbo-q5_0")
    }

    // MARK: - hotkeyDescription

    func testHotkeyDescriptionDelegatesToKeyMap() {
        let config = Config(
            whisperCliPath: "", whisperServerPath: "", whisperModelPath: "",
            language: "auto", hotkeyKeyCode: 63, hotkeyModifiers: [],
            llamaServerPath: "", llamaModelPath: "",
            ollamaEnabled: true, ollamaModel: "", ollamaEndpoint: "",
            launchAtLogin: false, logTranscriptions: true, punctuationEnabled: true
        )
        XCTAssertEqual(config.hotkeyDescription, "Fn")
    }
}
