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
            dictationMode: .smart,
            fileMode: .translate,
            translateTarget: "ru",
            replacements: ["Демале": "ДеМоле", "API": "АПИ"]
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
        XCTAssertEqual(decoded.dictationMode, config.dictationMode)
        XCTAssertEqual(decoded.fileMode, config.fileMode)
        XCTAssertEqual(decoded.translateTarget, config.translateTarget)
        XCTAssertEqual(decoded.replacements, config.replacements)
    }

    // MARK: - Backward compatibility

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

        XCTAssertEqual(config.whisperServerPath, "")
        XCTAssertEqual(config.llamaServerPath, "")
        XCTAssertEqual(config.llamaModelPath, "")
        XCTAssertEqual(config.launchAtLogin, false)
        XCTAssertEqual(config.logTranscriptions, false)
        // No legacy keys, no new keys — defaults
        XCTAssertEqual(config.dictationMode, .off)
        XCTAssertEqual(config.fileMode, Config.systemRAMGB > 8 ? .smart : .off)
        XCTAssertEqual(config.translateTarget, "en")
        XCTAssertEqual(config.replacements, [:])
    }

    /// Legacy v0.3b config with `punctuationEnabled` / `filePunctuationEnabled` booleans
    /// should migrate to the new mode enum values.
    func testDecodeLegacyPunctuationBooleansMigrate() throws {
        let json = """
        {
            "whisperCliPath": "/usr/bin/whisper",
            "whisperModelPath": "/models/model.bin",
            "language": "auto",
            "hotkeyKeyCode": 63,
            "hotkeyModifiers": [],
            "ollamaEnabled": true,
            "ollamaModel": "qwen2.5:3b",
            "ollamaEndpoint": "http://localhost:11434",
            "punctuationEnabled": true,
            "filePunctuationEnabled": false
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(Config.self, from: json)

        XCTAssertEqual(config.dictationMode, .smart, "legacy punctuationEnabled=true should become .smart")
        XCTAssertEqual(config.fileMode, .off, "legacy filePunctuationEnabled=false should become .off")
    }

    /// New keys win over legacy ones when both are present (forward-compat scenario).
    func testDecodeNewKeysWinOverLegacy() throws {
        let json = """
        {
            "whisperCliPath": "/usr/bin/whisper",
            "whisperModelPath": "/models/model.bin",
            "language": "auto",
            "hotkeyKeyCode": 63,
            "hotkeyModifiers": [],
            "ollamaEnabled": true,
            "ollamaModel": "qwen2.5:3b",
            "ollamaEndpoint": "http://localhost:11434",
            "punctuationEnabled": false,
            "filePunctuationEnabled": false,
            "dictationMode": "punctuation",
            "fileMode": "translate"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(Config.self, from: json)

        // "punctuation" raw value maps to .smart (legacy raw kept for v0.3b compat)
        XCTAssertEqual(config.dictationMode, .smart)
        XCTAssertEqual(config.fileMode, .translate)
    }

    /// Early 0.4b-dev builds shipped `grammar` / `list` raw values. Configs from
    /// those builds must not crash decode; unknown values fall back to defaults.
    func testDecodeUnknownModeRawFallsBackGracefully() throws {
        let json = """
        {
            "whisperCliPath": "/usr/bin/whisper",
            "whisperModelPath": "/models/model.bin",
            "language": "auto",
            "hotkeyKeyCode": 63,
            "hotkeyModifiers": [],
            "ollamaEnabled": true,
            "ollamaModel": "qwen2.5:3b",
            "ollamaEndpoint": "http://localhost:11434",
            "dictationMode": "grammar",
            "fileMode": "list"
        }
        """.data(using: .utf8)!

        // Must not throw — falls back to defaults rather than rejecting the whole config
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.dictationMode, .off, "unknown raw value should fall back to default")
        XCTAssertEqual(config.fileMode, Config.systemRAMGB > 8 ? .smart : .off,
                       "unknown raw value should fall back to default")
    }

    // MARK: - llamaAvailable

    private func makeBasicConfig(
        llamaServerPath: String,
        llamaModelPath: String,
        whisperModelPath: String = ""
    ) -> Config {
        Config(
            whisperCliPath: "", whisperServerPath: "", whisperModelPath: whisperModelPath,
            language: "auto", hotkeyKeyCode: 63, hotkeyModifiers: [],
            llamaServerPath: llamaServerPath, llamaModelPath: llamaModelPath,
            ollamaEnabled: true, ollamaModel: "", ollamaEndpoint: "",
            launchAtLogin: false, logTranscriptions: true,
            dictationMode: .smart, fileMode: .off
        )
    }

    func testLlamaAvailableBothSet() {
        let config = makeBasicConfig(llamaServerPath: "/bin/llama", llamaModelPath: "/models/model.gguf")
        XCTAssertTrue(config.llamaAvailable)
    }

    func testLlamaAvailableMissingServer() {
        let config = makeBasicConfig(llamaServerPath: "", llamaModelPath: "/models/model.gguf")
        XCTAssertFalse(config.llamaAvailable)
    }

    func testLlamaAvailableMissingModel() {
        let config = makeBasicConfig(llamaServerPath: "/bin/llama", llamaModelPath: "")
        XCTAssertFalse(config.llamaAvailable)
    }

    // MARK: - whisperModelName

    func testWhisperModelName() {
        let config = makeBasicConfig(
            llamaServerPath: "", llamaModelPath: "",
            whisperModelPath: "/path/to/ggml-large-v3-turbo-q5_0.bin"
        )
        XCTAssertEqual(config.whisperModelName, "large-v3-turbo-q5_0")
    }

    // MARK: - hotkeyDescription

    func testHotkeyDescriptionDelegatesToKeyMap() {
        let config = makeBasicConfig(llamaServerPath: "", llamaModelPath: "")
        XCTAssertEqual(config.hotkeyDescription, "Fn")
    }

    // MARK: - sanitizedOllamaEndpoint (SECURITY.md M1 — loopback-only)

    func testSanitizedOllamaEndpointAllowsLoopback() {
        XCTAssertEqual(Config.sanitizedOllamaEndpoint("http://localhost:11434"), "http://localhost:11434")
        XCTAssertEqual(Config.sanitizedOllamaEndpoint("http://127.0.0.1:11434"), "http://127.0.0.1:11434")
        XCTAssertEqual(Config.sanitizedOllamaEndpoint("https://localhost:443"), "https://localhost:443")
    }

    func testSanitizedOllamaEndpointRejectsRemote() {
        let def = Config.defaultOllamaEndpoint
        // Remote host → would exfiltrate dictation off-machine → reject
        XCTAssertEqual(Config.sanitizedOllamaEndpoint("https://attacker.example.com:11434"), def)
        XCTAssertEqual(Config.sanitizedOllamaEndpoint("http://192.168.1.50:11434"), def)
        XCTAssertEqual(Config.sanitizedOllamaEndpoint("http://10.0.0.1:11434"), def)
        // Malformed / non-http scheme → reject
        XCTAssertEqual(Config.sanitizedOllamaEndpoint("file:///etc/passwd"), def)
        XCTAssertEqual(Config.sanitizedOllamaEndpoint("not a url"), def)
        XCTAssertEqual(Config.sanitizedOllamaEndpoint(""), def)
    }
}
