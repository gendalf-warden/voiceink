import AppKit
import Foundation

public class StatusBarController {
    private var statusItem: NSStatusItem?
    private var animationTimer: Timer?
    private var animationPhase: CGFloat = 0

    // Cached icons — generated once
    private lazy var iconIdle = makeIcon(name: "mic", color: .secondaryLabelColor)
    private lazy var iconTranscribing = makeIcon(name: "waveform", color: .systemBlue)
    private lazy var iconProcessing = makeIcon(name: "brain", color: .systemPurple)
    private lazy var iconError = makeIcon(name: "exclamation", color: .systemRed)

    public var config: Config? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.rebuildMenu()
            }
        }
    }
    public var onQuit: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenLog: (() -> Void)?
    public var onTranscribeFile: (() -> Void)?
    public var onUndoDictation: (() -> Void)?
    public var onOpenReplacements: (() -> Void)?
    /// Called when the user changes a mode from the menu bar.
    /// `forFile` distinguishes dictation vs. file mode.
    public var onModeChange: ((_ forFile: Bool, _ mode: PostProcessingMode) -> Void)?

    /// Modes in display order for the submenu.
    private let modeOrder: [PostProcessingMode] = [.off, .punctuation, .grammar, .list, .translate]

    public var state: AppState = .idle {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.updateUI()
            }
        }
    }

    public init() {}

    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateUI()
    }

    private func updateUI() {
        guard let button = statusItem?.button else { return }

        stopAnimation()

        switch state {
        case .idle:
            button.image = iconIdle
            button.toolTip = "VoiceInk — Ready"
        case .recording:
            startRecordingAnimation()
            button.toolTip = "VoiceInk — Recording..."
        case .transcribing:
            button.image = iconTranscribing
            button.toolTip = "VoiceInk — Transcribing..."
        case .postProcessing:
            button.image = iconProcessing
            button.toolTip = "VoiceInk — Post-processing..."
        case .error:
            button.image = iconError
            button.toolTip = "VoiceInk — Error"
        }

        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Title with version
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let titleItem = NSMenuItem(title: "VoiceInk v\(version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // Status
        let stateItem = NSMenuItem(title: state.description, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(NSMenuItem.separator())

        // Info section
        if let config = config {
            let hotkeyItem = NSMenuItem(title: "Hotkey: \(config.hotkeyDescription) (push-to-talk)", action: nil, keyEquivalent: "")
            hotkeyItem.isEnabled = false
            menu.addItem(hotkeyItem)

            let modelItem = NSMenuItem(title: "Whisper: \(config.whisperModelName)", action: nil, keyEquivalent: "")
            modelItem.isEnabled = false
            menu.addItem(modelItem)

            let llmBackend: String
            if config.llamaAvailable {
                llmBackend = "qwen2.5:3b (bundled)"
            } else if config.ollamaEnabled {
                llmBackend = "\(config.ollamaModel) (Ollama)"
            } else {
                llmBackend = "none"
            }
            let llmItem = NSMenuItem(title: "LLM: \(llmBackend)", action: nil, keyEquivalent: "")
            llmItem.isEnabled = false
            menu.addItem(llmItem)

            // Dictation mode submenu
            menu.addItem(makeModeMenuItem(
                title: "Dictation: \(config.dictationMode.localizedName)",
                currentMode: config.dictationMode,
                forFile: false
            ))

            // File mode submenu
            menu.addItem(makeModeMenuItem(
                title: "File: \(config.fileMode.localizedName)",
                currentMode: config.fileMode,
                forFile: true
            ))

            let langItem = NSMenuItem(title: "Language: \(config.language)", action: nil, keyEquivalent: "")
            langItem.isEnabled = false
            menu.addItem(langItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Undo last dictation
        let undoItem = NSMenuItem(title: "Undo Dictation", action: #selector(undoDictationAction), keyEquivalent: "")
        undoItem.target = self
        menu.addItem(undoItem)

        // Transcribe file
        let transcribeItem = NSMenuItem(title: "Transcribe File…", action: #selector(transcribeFileAction), keyEquivalent: "")
        transcribeItem.target = self
        menu.addItem(transcribeItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Replacements editor
        let replacementsItem = NSMenuItem(title: "Replacements…", action: #selector(openReplacementsAction), keyEquivalent: "")
        replacementsItem.target = self
        menu.addItem(replacementsItem)

        // Open Log
        let logItem = NSMenuItem(title: "Open Log…", action: #selector(openLogAction), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit VoiceInk", action: #selector(quitAction), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func undoDictationAction() {
        onUndoDictation?()
    }

    @objc private func transcribeFileAction() {
        onTranscribeFile?()
    }

    @objc private func openSettingsAction() {
        onOpenSettings?()
    }

    @objc private func openReplacementsAction() {
        onOpenReplacements?()
    }

    @objc private func openLogAction() {
        onOpenLog?()
    }

    @objc private func quitAction() {
        onQuit?()
        NSApplication.shared.terminate(nil)
    }

    /// Build a submenu of modes (checkmark next to the current one) under a parent label.
    /// `forFile` differentiates dictation vs file mode when the user picks.
    private func makeModeMenuItem(title: String, currentMode: PostProcessingMode, forFile: Bool) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for mode in modeOrder {
            let item = NSMenuItem(
                title: mode.localizedName,
                action: forFile ? #selector(fileModeAction(_:)) : #selector(dictationModeAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = (mode == currentMode) ? .on : .off
            item.representedObject = mode.rawValue
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func dictationModeAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PostProcessingMode(rawValue: raw) else { return }
        onModeChange?(false, mode)
    }

    @objc private func fileModeAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PostProcessingMode(rawValue: raw) else { return }
        onModeChange?(true, mode)
    }

    // MARK: - Animation

    private func startRecordingAnimation() {
        animationPhase = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationPhase += 0.2
            self.statusItem?.button?.image = self.makeRecordingFrame()
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func makeRecordingFrame() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemRed.setFill()
            let barCount = 5
            let barWidth: CGFloat = 2.0
            let gap: CGFloat = 1.5
            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
            let startX = (rect.width - totalWidth) / 2

            for i in 0..<barCount {
                let phase = self.animationPhase + CGFloat(i) * 0.5
                let height = 4.0 + 10.0 * abs(sin(phase))
                let x = startX + CGFloat(i) * (barWidth + gap)
                let y = (rect.height - height) / 2
                let bar = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: height), xRadius: 1, yRadius: 1)
                bar.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Icons

    private func makeIcon(name: String, color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            color.setStroke()

            switch name {
            case "mic":
                let micBody = NSBezierPath(roundedRect: NSRect(x: 6, y: 7, width: 6, height: 8), xRadius: 3, yRadius: 3)
                micBody.fill()
                let stand = NSBezierPath()
                stand.move(to: NSPoint(x: 9, y: 5))
                stand.line(to: NSPoint(x: 9, y: 3))
                stand.lineWidth = 1.5
                stand.stroke()
                let base = NSBezierPath()
                base.move(to: NSPoint(x: 6, y: 3))
                base.line(to: NSPoint(x: 12, y: 3))
                base.lineWidth = 1.5
                base.stroke()
            case "waveform":
                let path = NSBezierPath()
                path.lineWidth = 1.5
                let points: [(CGFloat, CGFloat)] = [(3, 9), (5, 5), (7, 13), (9, 4), (11, 14), (13, 6), (15, 9)]
                for (i, p) in points.enumerated() {
                    if i == 0 { path.move(to: NSPoint(x: p.0, y: p.1)) }
                    else { path.line(to: NSPoint(x: p.0, y: p.1)) }
                }
                path.stroke()
            case "brain":
                let circle = NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 10, height: 10))
                circle.lineWidth = 1.5
                circle.stroke()
                let dot = NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 4, height: 4))
                dot.fill()
            case "exclamation":
                let triangle = NSBezierPath()
                triangle.move(to: NSPoint(x: 9, y: 16))
                triangle.line(to: NSPoint(x: 2, y: 3))
                triangle.line(to: NSPoint(x: 16, y: 3))
                triangle.close()
                triangle.lineWidth = 1.5
                triangle.stroke()
            default:
                break
            }
            return true
        }
        image.isTemplate = (name == "mic")
        return image
    }
}
