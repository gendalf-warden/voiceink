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

        case "uninstall":
            showUninstallConfirmation()

        default:
            print("Unknown window: \(windowName)")
            print("Available: replacements, settings, download, uninstall")
            NSApp.terminate(nil)
            return
        }

        // Bring window to front
        NSApp.activate(ignoringOtherApps: true)
    }

    func showUninstallConfirmation() {
        let w: CGFloat = 420
        let h: CGFloat = 320

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.level = .floating

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        window.contentView = content

        var y = h - 50

        // Warning icon
        let icon = NSTextField(labelWithString: "\u{26A0}\u{FE0F}")
        icon.font = NSFont.systemFont(ofSize: 36)
        icon.alignment = .center
        icon.frame = NSRect(x: 0, y: y, width: w, height: 44)
        content.addSubview(icon)
        y -= 40

        // Title
        let title = NSTextField(labelWithString: "Uninstall VoiceInk")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: y, width: w, height: 24)
        content.addSubview(title)
        y -= 28

        // Description
        let desc = NSTextField(wrappingLabelWithString:
            "This will permanently delete all VoiceInk data:\n\n"
            + "  \u{2022} ML models (~3.5 GB)\n"
            + "  \u{2022} Configuration and logs\n"
            + "  \u{2022} Launch Agent\n\n"
            + "To finish, open Applications folder, move VoiceInk to Trash and quit the app.")
        desc.font = NSFont.systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .left
        desc.frame = NSRect(x: 40, y: y - 110, width: w - 80, height: 110)
        content.addSubview(desc)
        y -= 124

        // Text field prompt
        let prompt = NSTextField(labelWithString: "Type delete to confirm:")
        prompt.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        prompt.frame = NSRect(x: 40, y: y, width: 200, height: 18)
        content.addSubview(prompt)
        y -= 28

        // Text field
        let textField = NSTextField(frame: NSRect(x: 40, y: y, width: w - 80, height: 24))
        textField.placeholderString = "delete"
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.bezelStyle = .roundedBezel
        content.addSubview(textField)
        y -= 40

        // Buttons
        let cancelBtn = NSButton(title: "Cancel", target: nil, action: #selector(NSWindow.close))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: w / 2 - 130, y: y, width: 120, height: 32)
        cancelBtn.target = window
        content.addSubview(cancelBtn)

        let deleteBtn = NSButton(title: "Uninstall", target: nil, action: nil)
        deleteBtn.bezelStyle = .rounded
        deleteBtn.contentTintColor = .systemRed
        deleteBtn.frame = NSRect(x: w / 2 + 10, y: y, width: 120, height: 32)
        deleteBtn.isEnabled = false
        content.addSubview(deleteBtn)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textField)

        // Poll text field to enable/disable button
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            guard window.isVisible else { timer.invalidate(); return }
            deleteBtn.isEnabled = textField.stringValue.lowercased().trimmingCharacters(in: .whitespaces) == "delete"
        }
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
