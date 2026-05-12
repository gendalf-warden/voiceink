import AppKit
import VoiceInkLib

// UIPreview — fast iteration harness for VoiceInk windows.
// Run: swift run UIPreview [window]
//   window = "replacements" (default) | "settings" | "result" | "firstrun"
//
// Force a UI language with VOICEINK_LANG env var:
//   VOICEINK_LANG=ru swift run UIPreview settings
//   VOICEINK_LANG=en swift run UIPreview settings
//
// Uses an isolated config in /tmp so production config in ~/.config/voiceink is untouched.

// Force-set AppleLanguages BEFORE any localized lookup happens.
// This must be at the top of main.swift so Bundle has not cached strings yet.
if let lang = ProcessInfo.processInfo.environment["VOICEINK_LANG"], !lang.isEmpty {
    UserDefaults.standard.set([lang], forKey: "AppleLanguages")
    UserDefaults.standard.synchronize()
    print("[UIPreview] Forced language: \(lang)")
}

let args = CommandLine.arguments
let windowName = args.count > 1 ? args[1].lowercased() : "replacements"

// Make a sample config with seed data for visual testing
var sampleConfig = Config(
    whisperCliPath: "/usr/bin/whisper",
    whisperServerPath: "/usr/bin/whisper-server",
    whisperModelPath: "/models/ggml-large-v3-turbo-q5_0.bin",
    language: "auto",
    hotkeyKeyCode: 63,
    hotkeyModifiers: [],
    llamaServerPath: "",
    llamaModelPath: "",
    ollamaEnabled: true,
    ollamaModel: "qwen2.5:3b",
    ollamaEndpoint: "http://localhost:11434",
    launchAtLogin: false,
    logTranscriptions: true,
    dictationMode: .smart,
    fileMode: .off,
    translateTarget: "en",
    replacements: [
        "Демале": "ДеМоле",
        "вагена": "вагона",
        "API": "АПИ",
        "Фиделио": "Fidelio",
    ]
)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

class PreviewDelegate: NSObject, NSApplicationDelegate {
    var replacementsWC: ReplacementsWindowController?
    var settingsWC: SettingsWindowController?
    var downloadWC: ModelDownloadWindowController?

    let windowName: String
    let config: Config

    init(windowName: String, config: Config) {
        self.windowName = windowName
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch windowName {
        case "replacements":
            replacementsWC = ReplacementsWindowController(config: config)
            replacementsWC?.onConfigChanged = { newConfig in
                print("[UIPreview] config changed — replacements:")
                for (k, v) in newConfig.replacements.sorted(by: { $0.key < $1.key }) {
                    print("  \(k) → \(v)")
                }
            }
            replacementsWC?.showWindow()

        case "settings":
            settingsWC = SettingsWindowController(config: config)
            settingsWC?.onConfigChanged = { newConfig in
                print("[UIPreview] config changed: dictation=\(newConfig.dictationMode.rawValue) file=\(newConfig.fileMode.rawValue) translateTo=\(newConfig.translateTarget)")
            }
            settingsWC?.showWindow()

        case "download":
            downloadWC = ModelDownloadWindowController()
            // Show with all models as "missing" for visual testing
            downloadWC?.show(models: ModelManager.assets) { success in
                print("[UIPreview] download completed: \(success)")
                NSApp.terminate(nil)
            }

        default:
            print("Unknown window: \(windowName)")
            print("Available: replacements, settings, download")
            NSApp.terminate(nil)
            return
        }

        // Bring window to front
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let delegate = PreviewDelegate(windowName: windowName, config: sampleConfig)
app.delegate = delegate
print("[UIPreview] Showing window: \(windowName)")
print("[UIPreview] Close window to quit.")
app.run()
