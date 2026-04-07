import AppKit
import AVFoundation
import Foundation

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var hotkeyManager: HotkeyManager!
    private var audioRecorder: AudioRecorder!
    private var transcriber: Transcriber!
    private var ollamaClient: OllamaClient?
    private var llamaClient: LlamaClient?
    private var config: Config!
    private var settingsWindow: SettingsWindowController?
    private var splash: SplashWindowController?
    private var serverAvailable = false
    private var fileTranscriptionManager: FileTranscriptionManager?
    private var firstRunWindow: FirstRunWindowController?
    private var history: [(date: Date, text: String)] = []
    private let maxHistory = 10

    private var state: AppState = .idle {
        didSet {
            statusBar.state = state
            log("State: \(state.description)")
        }
    }

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()
        log("Config loaded")

        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accGranted = AXIsProcessTrusted()
        if !micGranted || !accGranted {
            firstRunWindow = FirstRunWindowController()
            firstRunWindow?.show { [weak self] in
                self?.firstRunWindow = nil
                self?.startApp()
            }
            return
        }

        startApp()
    }

    private func startApp() {
        // Show splash immediately
        splash = SplashWindowController()
        splash?.show()
        splash?.setMilestone(0)
        log("Whisper CLI: \(config.whisperCliPath)")
        log("Model: \(config.whisperModelPath)")
        log("RAM: \(Config.systemRAMGB) GB, punctuation: \(config.punctuationEnabled)")

        // Status bar (lightweight, stays on main thread)
        statusBar = StatusBarController()
        statusBar.config = config
        statusBar.setup()
        statusBar.onQuit = { [weak self] in
            self?.shutdown()
        }
        statusBar.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        statusBar.onOpenLog = {
            NSWorkspace.shared.open(Logger.shared.logFile)
        }
        statusBar.onTranscribeFile = { [weak self] in
            self?.transcribeFile()
        }

        audioRecorder = AudioRecorder()

        // Heavy startup in background to keep splash responsive
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Milestone 1: Whisper server
            DispatchQueue.main.async { self.splash?.setMilestone(1) }
            self.transcriber = Transcriber(config: self.config)
            do {
                try self.transcriber.startServer()
                self.serverAvailable = self.transcriber.isServerRunning
                if !self.serverAvailable {
                    log("Whisper server failed to start — transcription will not work")
                }
            } catch {
                log("Failed to start whisper-server: \(error)")
            }

            // Milestone 2: LLM
            DispatchQueue.main.async { self.splash?.setMilestone(2) }
            if !self.config.punctuationEnabled {
                log("Punctuation disabled in settings — skipping LLM")
            } else if self.config.llamaAvailable {
                self.llamaClient = LlamaClient(serverPath: self.config.llamaServerPath, modelPath: self.config.llamaModelPath)
                do {
                    try self.llamaClient!.startServer()
                    log("Bundled LLM server started")
                    let semaphore = DispatchSemaphore(value: 0)
                    Task {
                        await self.llamaClient!.warmup()
                        semaphore.signal()
                    }
                    semaphore.wait()
                } catch {
                    log("Failed to start bundled LLM: \(error)")
                    self.llamaClient = nil
                }
            }
            if self.config.punctuationEnabled && self.llamaClient == nil && self.config.ollamaEnabled {
                self.ollamaClient = OllamaClient(endpoint: self.config.ollamaEndpoint, model: self.config.ollamaModel)
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    let available = await self.ollamaClient!.isAvailable()
                    log("Ollama available: \(available)")
                    if available {
                        log("Warming up LLM model...")
                        await self.ollamaClient!.warmup()
                    }
                    semaphore.signal()
                }
                semaphore.wait()
            }

            // Milestone 3: Permissions & hotkey
            DispatchQueue.main.async { self.splash?.setMilestone(3) }

            DispatchQueue.main.sync {
                self.hotkeyManager = HotkeyManager(keyCode: self.config.hotkeyKeyCode, modifiers: self.config.hotkeyModifiers)
                self.hotkeyManager.onKeyDown = { [weak self] in
                    self?.startRecording()
                }
                self.hotkeyManager.onKeyUp = { [weak self] in
                    self?.stopRecordingAndProcess()
                }

                AudioRecorder.requestPermission { granted in
                    if !granted {
                        log("Microphone permission denied!")
                    }
                }
                if !TextInserter.checkAccessibility() {
                    log("Accessibility permission needed for text insertion")
                }

                self.hotkeyManager.start()
            }

            // Milestone 4: Ready!
            DispatchQueue.main.async {
                self.splash?.setMilestone(4)
                log("Ready. Hotkey: \(self.config.hotkeyDescription)")
                self.state = .idle

                // Close splash after a brief moment to show "Ready!"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.splash?.close()
                    self.splash = nil
                }
            }
        }
    }

    // MARK: - Shutdown

    private func shutdown() {
        hotkeyManager.stop()
        transcriber.stopServer()
        llamaClient?.stopServer()

        // Unload LLM from VRAM
        if let ollamaClient = ollamaClient {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await ollamaClient.unloadModel()
                semaphore.signal()
            }
            // Wait up to 5s for unload
            _ = semaphore.wait(timeout: .now() + 5)
        }
    }

    // MARK: - Recording pipeline

    private func startRecording() {
        guard state == .idle else { return }

        guard serverAvailable else {
            state = .error("Whisper server not running")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if case .error = self?.state { self?.state = .idle }
            }
            return
        }

        do {
            let url = try audioRecorder.startRecording()
            state = .recording
            log("Recording to: \(url.lastPathComponent)")
        } catch {
            state = .error("Recording failed: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAndProcess() {
        guard state == .recording else { return }

        guard let audioURL = audioRecorder.stopRecording() else {
            state = .error("No audio file")
            return
        }

        state = .transcribing

        Task { [weak self] in
            guard let self = self else { return }
            do {
                // Step 1: Transcribe (async)
                let asrStart = Date()
                let rawText = try await self.transcriber.transcribe(audioURL: audioURL)
                    .stripCombiningAccents()
                let asrTime = Date().timeIntervalSince(asrStart)
                let rawDisplay = self.config.logTranscriptions ? rawText : "[\(rawText.count) chars]"
                log("Raw (\(String(format: "%.1f", asrTime))s): \(rawDisplay)")

                guard !rawText.isEmpty else {
                    await MainActor.run { self.state = .idle }
                    return
                }

                // Step 2: Post-process with LLM (bundled llama → Ollama → raw)
                let llamaReady = self.llamaClient?.isServerRunning == true
                let ollamaReady = self.ollamaClient != nil && self.config.ollamaEnabled
                let llmAvailable = llamaReady || ollamaReady
                if llmAvailable {
                    await MainActor.run { self.state = .postProcessing }

                    let useLlama = self.llamaClient?.isServerRunning == true

                    do {
                        let llmStart = Date()
                        let processed: String
                        if useLlama, let llamaClient = self.llamaClient {
                            processed = try await llamaClient.postProcess(text: rawText)
                        } else if let ollamaClient = self.ollamaClient {
                            processed = try await ollamaClient.postProcess(text: rawText)
                        } else {
                            throw NSError(domain: "VoiceInk", code: -1, userInfo: [NSLocalizedDescriptionKey: "No LLM available"])
                        }
                        let llmTime = Date().timeIntervalSince(llmStart)
                        let procDisplay = self.config.logTranscriptions ? processed : "[\(processed.count) chars]"
                        log("Processed (\(String(format: "%.1f", llmTime))s): \(procDisplay)")
                        await MainActor.run {
                            TextInserter().insert(text: processed)
                            self.state = .idle
                        }
                    } catch {
                        log("LLM failed: \(error). Using raw text.")
                        await MainActor.run {
                            TextInserter().insert(text: rawText)
                            self.state = .idle
                        }
                    }
                } else {
                    // No LLM — insert raw text
                    await MainActor.run {
                        TextInserter().insert(text: rawText)
                        self.state = .idle
                    }
                }

                // Cleanup temp file
                try? FileManager.default.removeItem(at: audioURL)
            } catch {
                await MainActor.run {
                    self.state = .error(error.localizedDescription)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if case .error = self.state { self.state = .idle }
                    }
                }
            }
        }
    }

    // MARK: - File Transcription

    private func transcribeFile() {
        guard serverAvailable else {
            log("Cannot transcribe file — whisper server not running")
            return
        }
        if fileTranscriptionManager == nil {
            fileTranscriptionManager = FileTranscriptionManager()
        }
        fileTranscriptionManager?.llamaClient = llamaClient
        fileTranscriptionManager?.ollamaClient = ollamaClient
        fileTranscriptionManager?.punctuationEnabled = config.punctuationEnabled
        fileTranscriptionManager?.startFileTranscription(transcriber: transcriber)
    }

    // MARK: - Settings

    private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(config: config)
            settingsWindow?.onConfigChanged = { [weak self] newConfig in
                self?.applyConfig(newConfig)
            }
        }
        settingsWindow?.showWindow()
        settingsWindow?.updateConfig(config)
    }

    /// Apply config changes live without restarting the app
    private func applyConfig(_ newConfig: Config) {
        let hotkeyChanged = newConfig.hotkeyKeyCode != config.hotkeyKeyCode
            || newConfig.hotkeyModifiers != config.hotkeyModifiers
        let launchChanged = newConfig.launchAtLogin != config.launchAtLogin

        config = newConfig

        // Update status bar info
        statusBar.config = config

        // Hot-reload hotkey
        if hotkeyChanged {
            hotkeyManager.updateHotkey(keyCode: config.hotkeyKeyCode, modifiers: config.hotkeyModifiers)
            log("Hotkey reloaded: \(config.hotkeyDescription)")
        }

        // Update LaunchAgent
        if launchChanged {
            updateLaunchAgent()
        }
    }

    private func updateLaunchAgent() {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsDir.appendingPathComponent("com.voiceink.app.plist")

        if config.launchAtLogin {
            let executablePath = ProcessInfo.processInfo.arguments[0]
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.voiceink.app</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(executablePath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            do {
                try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
                try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
                log("Launch at Login: enabled")
            } catch {
                log("Failed to create LaunchAgent: \(error)")
            }
        } else {
            try? FileManager.default.removeItem(at: plistPath)
            log("Launch at Login: disabled")
        }
    }
}

// stripCombiningAccents() moved to StringExtensions.swift
