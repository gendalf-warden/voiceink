import Foundation

public struct Config: Codable {
    public var whisperCliPath: String
    public var whisperServerPath: String
    public var whisperModelPath: String
    public var language: String
    public var hotkeyKeyCode: UInt16
    public var hotkeyModifiers: [String]
    public var llamaServerPath: String
    public var llamaModelPath: String
    public var ollamaEnabled: Bool
    public var ollamaModel: String
    public var ollamaEndpoint: String
    public var launchAtLogin: Bool
    public var logTranscriptions: Bool
    /// Smart punctuation for voice dictation (push-to-talk). Short phrases benefit from it.
    public var punctuationEnabled: Bool
    /// Smart punctuation for file transcription. Off by default — raw Whisper output is usually
    /// good enough, and LLM adds ~60% processing time plus ~10% risk of word substitution.
    public var filePunctuationEnabled: Bool

    public init(
        whisperCliPath: String, whisperServerPath: String, whisperModelPath: String,
        language: String, hotkeyKeyCode: UInt16, hotkeyModifiers: [String],
        llamaServerPath: String, llamaModelPath: String,
        ollamaEnabled: Bool, ollamaModel: String, ollamaEndpoint: String,
        launchAtLogin: Bool, logTranscriptions: Bool,
        punctuationEnabled: Bool, filePunctuationEnabled: Bool
    ) {
        self.whisperCliPath = whisperCliPath
        self.whisperServerPath = whisperServerPath
        self.whisperModelPath = whisperModelPath
        self.language = language
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.llamaServerPath = llamaServerPath
        self.llamaModelPath = llamaModelPath
        self.ollamaEnabled = ollamaEnabled
        self.ollamaModel = ollamaModel
        self.ollamaEndpoint = ollamaEndpoint
        self.launchAtLogin = launchAtLogin
        self.logTranscriptions = logTranscriptions
        self.punctuationEnabled = punctuationEnabled
        self.filePunctuationEnabled = filePunctuationEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        whisperCliPath = try container.decode(String.self, forKey: .whisperCliPath)
        whisperServerPath = try container.decodeIfPresent(String.self, forKey: .whisperServerPath) ?? ""
        whisperModelPath = try container.decode(String.self, forKey: .whisperModelPath)
        language = try container.decode(String.self, forKey: .language)
        hotkeyKeyCode = try container.decode(UInt16.self, forKey: .hotkeyKeyCode)
        hotkeyModifiers = try container.decode([String].self, forKey: .hotkeyModifiers)
        llamaServerPath = try container.decodeIfPresent(String.self, forKey: .llamaServerPath) ?? ""
        llamaModelPath = try container.decodeIfPresent(String.self, forKey: .llamaModelPath) ?? ""
        ollamaEnabled = try container.decode(Bool.self, forKey: .ollamaEnabled)
        ollamaModel = try container.decode(String.self, forKey: .ollamaModel)
        ollamaEndpoint = try container.decode(String.self, forKey: .ollamaEndpoint)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        logTranscriptions = try container.decodeIfPresent(Bool.self, forKey: .logTranscriptions) ?? true
        punctuationEnabled = try container.decodeIfPresent(Bool.self, forKey: .punctuationEnabled) ?? (Config.systemRAMGB > 8)
        filePunctuationEnabled = try container.decodeIfPresent(Bool.self, forKey: .filePunctuationEnabled) ?? false
    }

    public static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voiceink")
    public static let configFile = configDir.appendingPathComponent("config.json")

    public static let defaultConfig = Config(
        whisperCliPath: "",
        whisperServerPath: "",
        whisperModelPath: "",
        language: "auto",
        hotkeyKeyCode: 63, // Fn key
        hotkeyModifiers: [],
        llamaServerPath: "",
        llamaModelPath: "",
        ollamaEnabled: true,
        ollamaModel: "qwen2.5:3b",
        ollamaEndpoint: "http://localhost:11434",
        launchAtLogin: false,
        logTranscriptions: true,
        punctuationEnabled: systemRAMGB > 8,
        filePunctuationEnabled: false
    )

    /// System RAM in GB
    public static let systemRAMGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)

    /// Human-readable hotkey description
    public var hotkeyDescription: String {
        KeyMap.hotkeyDescription(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    /// Whether bundled llama-server + model are available
    public var llamaAvailable: Bool {
        !llamaServerPath.isEmpty && !llamaModelPath.isEmpty
    }

    /// Whisper model short name
    public var whisperModelName: String {
        let filename = URL(fileURLWithPath: whisperModelPath).lastPathComponent
        return filename
            .replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: ".bin", with: "")
    }

    public static func load() -> Config {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            let config = detectDefaults()
            config.save()
            return config
        }
        do {
            let data = try Data(contentsOf: configFile)
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            log("Failed to load: \(error). Using defaults.", tag: "Config")
            return detectDefaults()
        }
    }

    public func save() {
        do {
            try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: Config.configFile)
        } catch {
            log("Failed to save: \(error)", tag: "Config")
        }
    }

    private static func detectDefaults() -> Config {
        var config = defaultConfig
        let fm = FileManager.default
        let resourcePath = Bundle.main.resourcePath

        // Detect whisper-server (bundle first, then derive from whisper-cli)
        let serverPaths = [
            resourcePath.map { $0 + "/whisper-server" },
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Claude/Whispier cli/whisper.cpp/build/bin/whisper-server").path,
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server",
        ].compactMap { $0 }
        for path in serverPaths {
            if fm.isExecutableFile(atPath: path) {
                config.whisperServerPath = path
                break
            }
        }

        // Detect whisper-cli (for backwards compat / dev mode)
        let whisperPaths = [
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Claude/Whispier cli/whisper.cpp/build/bin/whisper-cli").path,
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ]
        for path in whisperPaths {
            if fm.isExecutableFile(atPath: path) {
                config.whisperCliPath = path
                break
            }
        }

        // Detect model (bundle first)
        let modelPaths = [
            resourcePath.map { $0 + "/models/ggml-large-v3-turbo-q5_0.bin" },
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Claude/Whispier cli/models/ggml-large-v3-turbo-q5_0.bin").path,
            "/opt/homebrew/share/whisper-cpp/models/ggml-large-v3-turbo.bin",
        ].compactMap { $0 }
        for path in modelPaths {
            if fm.fileExists(atPath: path) {
                config.whisperModelPath = path
                break
            }
        }

        // Detect llama-server (bundle first)
        let llamaServerPaths = [
            resourcePath.map { $0 + "/llama-server" },
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
        ].compactMap { $0 }
        for path in llamaServerPaths {
            if fm.isExecutableFile(atPath: path) {
                config.llamaServerPath = path
                break
            }
        }

        // Detect qwen model (bundle first, then Ollama blobs)
        let llamaModelPaths = [
            resourcePath.map { $0 + "/models/qwen2.5-3b.gguf" },
        ].compactMap { $0 }
        for path in llamaModelPaths {
            if fm.fileExists(atPath: path) {
                config.llamaModelPath = path
                break
            }
        }

        return config
    }
}
