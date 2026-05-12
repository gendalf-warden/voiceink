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
    private var replacementsWindow: ReplacementsWindowController?
    private var splash: SplashWindowController?
    private var serverAvailable = false
    private var fileTranscriptionManager: FileTranscriptionManager?
    private var firstRunWindow: FirstRunWindowController?
    private var downloadWindow: ModelDownloadWindowController?
    private var history: [(date: Date, text: String)] = []
    private let maxHistory = 10
    private var recordingStartTime: Date?
    private let minRecordingDuration: TimeInterval = 0.5
    private let textInserter = TextInserter()
    /// True when LLM is loaded eagerly at startup (because dictation needs it warm).
    /// When false but file transcription needs LLM, we load lazily per-file.
    private var llmEagerlyLoaded = false

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
                // Brief delay to let the first-run window fully close
                // before showing the next window (model download or splash).
                // Without this, LSUIElement apps may lose focus and the next
                // window appears behind other windows.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self?.checkModelsAndStart()
                }
            }
            return
        }

        checkModelsAndStart()
    }

    /// Check if required ML models are present. If any are missing, show download window.
    /// Once models are ready (or already present), proceed to startApp().
    private func checkModelsAndStart() {
        log("checkModelsAndStart() called", tag: "Models")
        let missing = ModelManager.missingModels()
        log("Missing models: \(missing.count) (\(missing.map(\.id).joined(separator: ", ")))", tag: "Models")
        if missing.isEmpty {
            startApp()
            return
        }

        log("Showing download window for \(missing.count) model(s)", tag: "Models")
        downloadWindow = ModelDownloadWindowController()
        downloadWindow?.show(models: missing) { [weak self] success in
            self?.downloadWindow = nil
            if success {
                // Re-detect config so model paths point to Application Support
                self?.config = Config.load()
                self?.startApp()
            } else {
                log("Model download cancelled or failed — exiting", tag: "Models")
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func startApp() {
        // Show splash immediately
        splash = SplashWindowController()
        splash?.show()
        splash?.setMilestone(0)
        log("Whisper CLI: \(config.whisperCliPath)")
        log("Model: \(config.whisperModelPath)")
        log("RAM: \(Config.systemRAMGB) GB, dictation: \(config.dictationMode.rawValue), file: \(config.fileMode.rawValue)")

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
        statusBar.onUndoDictation = { [weak self] in
            self?.textInserter.undoLastInsertion()
        }
        statusBar.onOpenReplacements = { [weak self] in
            self?.openReplacements()
        }
        statusBar.onModeChange = { [weak self] forFile, mode in
            guard let self = self else { return }
            if forFile {
                self.config.fileMode = mode
            } else {
                self.config.dictationMode = mode
            }
            self.config.save()
            self.applyConfig(self.config)
            log("Mode changed (\(forFile ? "file" : "dictation")): \(mode.rawValue)", tag: "StatusBar")
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
            // Eager load (always-warm): only if dictation needs it (sub-second latency required).
            // File transcription lazy-loads on demand and unloads after (saves ~2 GB idle RAM).
            DispatchQueue.main.async { self.splash?.setMilestone(2) }
            if self.config.dictationMode != .off {
                self.llmEagerlyLoaded = true
                self.startLLMSync()
            } else if self.config.fileMode != .off {
                log("LLM lazy mode: will load only during file transcription")
            } else {
                log("Post-processing disabled for both dictation and files — LLM never loaded")
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
            recordingStartTime = Date()
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

        // Skip very short recordings (accidental Fn tap)
        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)
            if duration < minRecordingDuration {
                log("Recording too short (\(String(format: "%.2f", duration))s < \(minRecordingDuration)s) — skipping")
                try? FileManager.default.removeItem(at: audioURL)
                state = .idle
                return
            }
        }
        recordingStartTime = nil

        state = .transcribing

        Task { [weak self] in
            guard let self = self else { return }
            do {
                // Step 1: Transcribe (async)
                let asrStart = Date()
                let asrText = try await self.transcriber.transcribe(audioURL: audioURL)
                    .stripCombiningAccents()
                let asrTime = Date().timeIntervalSince(asrStart)

                // Step 1.5: Apply user replacements dictionary (after Whisper, before LLM)
                let rawText = TextReplacer.apply(asrText, replacements: self.config.replacements)
                if rawText != asrText {
                    log("Replacements applied: '\(asrText)' → '\(rawText)'")
                }

                let rawDisplay = self.config.logTranscriptions ? rawText : "[\(rawText.count) chars]"
                log("Raw (\(String(format: "%.1f", asrTime))s): \(rawDisplay)")

                guard !rawText.isEmpty else {
                    await MainActor.run { self.state = .idle }
                    return
                }

                // Step 2: Post-process with LLM if mode != .off (bundled llama → Ollama → raw)
                let mode = self.config.dictationMode
                let systemPrompt = mode.systemPrompt(translateTarget: self.config.translateTarget)
                let llamaReady = self.llamaClient?.isServerRunning == true
                let ollamaReady = self.ollamaClient != nil && self.config.ollamaEnabled
                let llmAvailable = (llamaReady || ollamaReady) && systemPrompt != nil
                if llmAvailable, let prompt = systemPrompt {
                    await MainActor.run { self.state = .postProcessing }

                    let useLlama = self.llamaClient?.isServerRunning == true

                    do {
                        let llmStart = Date()
                        let processed: String
                        if useLlama, let llamaClient = self.llamaClient {
                            processed = try await llamaClient.process(text: rawText, systemPrompt: prompt)
                        } else if let ollamaClient = self.ollamaClient {
                            processed = try await ollamaClient.process(text: rawText, systemPrompt: prompt)
                        } else {
                            throw NSError(domain: "VoiceInk", code: -1, userInfo: [NSLocalizedDescriptionKey: "No LLM available"])
                        }
                        let llmTime = Date().timeIntervalSince(llmStart)

                        // Guard against LLM hallucination: if output is 3x+ longer than input, use raw.
                        // Skip for .translate — translation length is genuinely unpredictable.
                        let finalText: String
                        if mode != .translate && processed.count > rawText.count * 3 {
                            log("LLM output too long (\(processed.count) vs \(rawText.count) chars) — using raw text", tag: "LLM")
                            finalText = rawText
                        } else {
                            finalText = processed
                        }

                        let procDisplay = self.config.logTranscriptions ? finalText : "[\(finalText.count) chars]"
                        log("Processed (\(String(format: "%.1f", llmTime))s): \(procDisplay)")
                        await MainActor.run {
                            self.textInserter.insert(text: finalText)
                            self.state = .idle
                        }
                    } catch {
                        log("LLM failed: \(error). Using raw text.")
                        await MainActor.run {
                            self.textInserter.insert(text: rawText)
                            self.state = .idle
                        }
                    }
                } else {
                    // No LLM — insert raw text
                    await MainActor.run {
                        self.textInserter.insert(text: rawText)
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

    // MARK: - LLM lifecycle

    /// Synchronously start LLM (bundled llama-server preferred, Ollama fallback) and warm it up.
    /// Used at startup when dictation needs the LLM always-warm.
    private func startLLMSync() {
        if config.llamaAvailable {
            llamaClient = LlamaClient(serverPath: config.llamaServerPath, modelPath: config.llamaModelPath)
            do {
                try llamaClient!.startServer()
                log("Bundled LLM server started")
                let sem = DispatchSemaphore(value: 0)
                Task {
                    await self.llamaClient!.warmup()
                    sem.signal()
                }
                sem.wait()
                return
            } catch {
                log("Failed to start bundled LLM: \(error)")
                llamaClient = nil
            }
        }
        if config.ollamaEnabled {
            ollamaClient = OllamaClient(endpoint: config.ollamaEndpoint, model: config.ollamaModel)
            let sem = DispatchSemaphore(value: 0)
            Task {
                let available = await self.ollamaClient!.isAvailable()
                log("Ollama available: \(available)")
                if available {
                    log("Warming up LLM model...")
                    await self.ollamaClient!.warmup()
                }
                sem.signal()
            }
            sem.wait()
        }
    }

    /// Ensure LLM is ready for an on-demand request (file transcription).
    /// No-op if already loaded eagerly. Returns true if LLM is now available.
    private func ensureLLMReady() async -> Bool {
        if llmEagerlyLoaded { return llamaClient?.isServerRunning == true || ollamaClient != nil }
        if llamaClient?.isServerRunning == true { return true }
        if ollamaClient != nil { return true }
        log("Lazy-loading LLM for file transcription...")
        await Task.detached { [weak self] in self?.startLLMSync() }.value
        return llamaClient?.isServerRunning == true || ollamaClient != nil
    }

    /// Release lazily-loaded LLM after a file transcription. No-op if eagerly loaded.
    private func releaseLazyLLM() async {
        guard !llmEagerlyLoaded else { return }
        if let llama = llamaClient {
            llama.stopServer()
            llamaClient = nil
            log("Lazy LLM unloaded (bundled llama-server)")
        }
        if let ollama = ollamaClient {
            await ollama.unloadModel()
            ollamaClient = nil
            log("Lazy LLM unloaded (Ollama)")
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
        let manager = fileTranscriptionManager!
        manager.mode = config.fileMode
        manager.translateTarget = config.translateTarget
        manager.replacements = config.replacements
        manager.onLLMNeeded = { [weak self] in
            await self?.ensureLLMReady() ?? false
        }
        manager.onLLMRelease = { [weak self] in
            await self?.releaseLazyLLM()
        }
        manager.llamaClientProvider = { [weak self] in self?.llamaClient }
        manager.ollamaClientProvider = { [weak self] in self?.ollamaClient }
        manager.startFileTranscription(transcriber: transcriber)
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

    private func openReplacements() {
        if replacementsWindow == nil {
            replacementsWindow = ReplacementsWindowController(config: config)
            replacementsWindow?.onConfigChanged = { [weak self] newConfig in
                self?.applyConfig(newConfig)
            }
        }
        replacementsWindow?.updateConfig(config)
        replacementsWindow?.showWindow()
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

// MARK: - Hybrid Dock management

extension NSApplication {
    /// Temporarily show the Dock icon so windows get proper focus and Cmd+Tab.
    /// Call before showing any window. Safe to call multiple times.
    func showDock() {
        if activationPolicy() != .regular {
            setActivationPolicy(.regular)
        }
        activate(ignoringOtherApps: true)
    }

    /// Hide the Dock icon when no visible windows remain.
    /// Call after closing a window. Uses a brief delay to let the close animation finish.
    func hideDockIfNoWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            let hasWindows = self.windows.contains { $0.isVisible }
            if !hasWindows {
                self.setActivationPolicy(.accessory)
            }
        }
    }
}
