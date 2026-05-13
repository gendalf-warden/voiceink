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
    /// Post-processing applied to dictation (push-to-talk) output.
    /// Was `punctuationEnabled: Bool` before v0.4b; legacy field is read on decode for migration.
    public var dictationMode: PostProcessingMode
    /// Post-processing applied to file transcription output.
    /// Was `filePunctuationEnabled: Bool` before v0.4b; legacy field is read on decode for migration.
    public var fileMode: PostProcessingMode
    /// Target language code for `.translate` mode (e.g. "en", "ru"). ISO 639-1.
    /// Ignored unless one of the modes is `.translate`.
    public var translateTarget: String
    /// User-defined word replacements applied after Whisper, before LLM.
    /// Keys are Whisper output forms, values are the corrected forms.
    /// Example: ["Демале": "ДеМоле", "вагена": "вагона"].
    /// Matching is case-insensitive but the value is inserted verbatim.
    public var replacements: [String: String]

    public init(
        whisperCliPath: String, whisperServerPath: String, whisperModelPath: String,
        language: String, hotkeyKeyCode: UInt16, hotkeyModifiers: [String],
        llamaServerPath: String, llamaModelPath: String,
        ollamaEnabled: Bool, ollamaModel: String, ollamaEndpoint: String,
        launchAtLogin: Bool, logTranscriptions: Bool,
        dictationMode: PostProcessingMode, fileMode: PostProcessingMode,
        translateTarget: String = "en",
        replacements: [String: String] = [:]
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
        self.dictationMode = dictationMode
        self.fileMode = fileMode
        self.translateTarget = translateTarget
        self.replacements = replacements
    }

    private enum CodingKeys: String, CodingKey {
        case whisperCliPath, whisperServerPath, whisperModelPath
        case language, hotkeyKeyCode, hotkeyModifiers
        case llamaServerPath, llamaModelPath
        case ollamaEnabled, ollamaModel, ollamaEndpoint
        case launchAtLogin, logTranscriptions
        case dictationMode, fileMode, translateTarget
        case replacements
        // Legacy keys (pre-v0.4b) — decode-only for migration
        case punctuationEnabled, filePunctuationEnabled
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
        logTranscriptions = try container.decodeIfPresent(Bool.self, forKey: .logTranscriptions) ?? false

        // Decode modes — prefer new keys, fall back to legacy booleans for migration.
        // Tolerant of unknown raw values (e.g. "grammar"/"list" from early 0.4b-dev
        // builds): treat unknown mode strings as if the key were absent.
        if let raw = try container.decodeIfPresent(String.self, forKey: .dictationMode),
           let mode = PostProcessingMode(rawValue: raw) {
            dictationMode = mode
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .punctuationEnabled) {
            dictationMode = legacy ? .smart : .off
        } else {
            dictationMode = .off
        }
        if let raw = try container.decodeIfPresent(String.self, forKey: .fileMode),
           let mode = PostProcessingMode(rawValue: raw) {
            fileMode = mode
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .filePunctuationEnabled) {
            fileMode = legacy ? .smart : .off
        } else {
            fileMode = Config.systemRAMGB > 8 ? .smart : .off
        }
        translateTarget = try container.decodeIfPresent(String.self, forKey: .translateTarget) ?? "en"

        replacements = try container.decodeIfPresent([String: String].self, forKey: .replacements) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(whisperCliPath, forKey: .whisperCliPath)
        try container.encode(whisperServerPath, forKey: .whisperServerPath)
        try container.encode(whisperModelPath, forKey: .whisperModelPath)
        try container.encode(language, forKey: .language)
        try container.encode(hotkeyKeyCode, forKey: .hotkeyKeyCode)
        try container.encode(hotkeyModifiers, forKey: .hotkeyModifiers)
        try container.encode(llamaServerPath, forKey: .llamaServerPath)
        try container.encode(llamaModelPath, forKey: .llamaModelPath)
        try container.encode(ollamaEnabled, forKey: .ollamaEnabled)
        try container.encode(ollamaModel, forKey: .ollamaModel)
        try container.encode(ollamaEndpoint, forKey: .ollamaEndpoint)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(logTranscriptions, forKey: .logTranscriptions)
        try container.encode(dictationMode, forKey: .dictationMode)
        try container.encode(fileMode, forKey: .fileMode)
        try container.encode(translateTarget, forKey: .translateTarget)
        try container.encode(replacements, forKey: .replacements)
    }

    /// Config directory. Overridable via VOICEINK_CONFIG_DIR env var (used by UIPreview tests
    /// to avoid clobbering the production config).
    public static let configDir: URL = {
        if let override = ProcessInfo.processInfo.environment["VOICEINK_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voiceink")
    }()
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
        logTranscriptions: false,
        dictationMode: .off,
        fileMode: systemRAMGB > 8 ? .smart : .off,
        translateTarget: "en",
        replacements: [:]
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
            var config = try JSONDecoder().decode(Config.self, from: data)
            if redetectStalePaths(&config) {
                config.save()
            }
            return config
        } catch {
            log("Failed to load: \(error). Using defaults.", tag: "Config")
            return detectDefaults()
        }
    }

    /// Check that binary/model paths still exist on disk. If the user moved
    /// the .app (e.g. ~/Applications → /Applications), the saved paths go
    /// stale. Re-runs detectDefaults() for any missing path and returns true
    /// if anything changed so the caller can save.
    private static func redetectStalePaths(_ config: inout Config) -> Bool {
        let fm = FileManager.default
        let fresh = detectDefaults()
        var changed = false

        if !config.whisperServerPath.isEmpty && !fm.isExecutableFile(atPath: config.whisperServerPath) {
            log("whisperServerPath stale: \(config.whisperServerPath) → \(fresh.whisperServerPath)", tag: "Config")
            config.whisperServerPath = fresh.whisperServerPath
            changed = true
        }
        if !config.whisperModelPath.isEmpty && !fm.fileExists(atPath: config.whisperModelPath) {
            log("whisperModelPath stale: \(config.whisperModelPath) → \(fresh.whisperModelPath)", tag: "Config")
            config.whisperModelPath = fresh.whisperModelPath
            changed = true
        }
        if !config.llamaServerPath.isEmpty && !fm.isExecutableFile(atPath: config.llamaServerPath) {
            log("llamaServerPath stale: \(config.llamaServerPath) → \(fresh.llamaServerPath)", tag: "Config")
            config.llamaServerPath = fresh.llamaServerPath
            changed = true
        }
        if !config.llamaModelPath.isEmpty && !fm.fileExists(atPath: config.llamaModelPath) {
            log("llamaModelPath stale: \(config.llamaModelPath) → \(fresh.llamaModelPath)", tag: "Config")
            config.llamaModelPath = fresh.llamaModelPath
            changed = true
        }
        return changed
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

        // Detect model (Application Support first, then bundle, then dev paths)
        let modelPaths = [
            ModelManager.modelsDir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path as String?,
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

        // Detect qwen model (Application Support first, then bundle)
        let llamaModelPaths = [
            ModelManager.modelsDir.appendingPathComponent("qwen2.5-3b.gguf").path as String?,
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
