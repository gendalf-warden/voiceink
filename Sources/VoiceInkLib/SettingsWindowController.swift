import AppKit
import Foundation

public class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hotkeyField: HotkeyRecorderField!
    private var launchAtLoginCheckbox: NSButton!
    private var logTranscriptionsCheckbox: NSButton!
    private var punctuationCheckbox: NSButton!
    private var filePunctuationCheckbox: NSButton!

    private var config: Config
    public var onConfigChanged: ((Config) -> Void)?

    public init(config: Config) {
        self.config = config
        super.init()
    }

    public func showWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let width: CGFloat = 500
        let height: CGFloat = 280

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceInk Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = contentView

        let checkboxLeft: CGFloat = 110
        let checkboxWidth: CGFloat = width - checkboxLeft - 20

        // --- Hotkey row ---
        let hotkeyLabel = NSTextField(labelWithString: "Hotkey:")
        hotkeyLabel.frame = NSRect(x: 20, y: height - 50, width: 80, height: 22)
        hotkeyLabel.alignment = .right
        contentView.addSubview(hotkeyLabel)

        hotkeyField = HotkeyRecorderField(
            frame: NSRect(x: checkboxLeft, y: height - 52, width: 200, height: 28)
        )
        hotkeyField.keyCode = config.hotkeyKeyCode
        hotkeyField.modifiers = config.hotkeyModifiers
        hotkeyField.onHotkeyChanged = { [weak self] keyCode, modifiers in
            guard let self = self else { return }
            self.config.hotkeyKeyCode = keyCode
            self.config.hotkeyModifiers = modifiers
            self.config.save()
            self.onConfigChanged?(self.config)
            log("Hotkey changed to: \(self.config.hotkeyDescription)")
        }
        contentView.addSubview(hotkeyField)

        // --- Launch at Login row ---
        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(launchAtLoginToggled))
        launchAtLoginCheckbox.frame = NSRect(x: checkboxLeft, y: height - 90, width: checkboxWidth, height: 22)
        launchAtLoginCheckbox.state = config.launchAtLogin ? .on : .off
        contentView.addSubview(launchAtLoginCheckbox)

        // --- Log transcriptions row ---
        logTranscriptionsCheckbox = NSButton(checkboxWithTitle: "Log transcription text", target: self, action: #selector(logTranscriptionsToggled))
        logTranscriptionsCheckbox.frame = NSRect(x: checkboxLeft, y: height - 120, width: checkboxWidth, height: 22)
        logTranscriptionsCheckbox.state = config.logTranscriptions ? .on : .off
        contentView.addSubview(logTranscriptionsCheckbox)

        // --- Smart punctuation: dictation ---
        punctuationCheckbox = NSButton(checkboxWithTitle: "Умная пунктуация при диктовке", target: self, action: #selector(punctuationToggled))
        punctuationCheckbox.frame = NSRect(x: checkboxLeft, y: height - 150, width: checkboxWidth, height: 22)
        punctuationCheckbox.state = config.punctuationEnabled ? .on : .off
        contentView.addSubview(punctuationCheckbox)

        // --- Smart punctuation: file transcription ---
        filePunctuationCheckbox = NSButton(checkboxWithTitle: "Умная пунктуация при транскрипции файлов", target: self, action: #selector(filePunctuationToggled))
        filePunctuationCheckbox.frame = NSRect(x: checkboxLeft, y: height - 180, width: checkboxWidth, height: 22)
        filePunctuationCheckbox.state = config.filePunctuationEnabled ? .on : .off
        contentView.addSubview(filePunctuationCheckbox)

        // --- Hint ---
        let hint = NSTextField(wrappingLabelWithString: "Click the hotkey field, then press a key combo (e.g. \u{2303}1) or Fn alone.")
        hint.frame = NSRect(x: 20, y: 16, width: width - 40, height: 34)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        contentView.addSubview(hint)

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func logTranscriptionsToggled() {
        config.logTranscriptions = (logTranscriptionsCheckbox.state == .on)
        config.save()
        onConfigChanged?(config)
        log("Log transcriptions: \(config.logTranscriptions)")
    }

    @objc private func punctuationToggled() {
        config.punctuationEnabled = (punctuationCheckbox.state == .on)
        config.save()
        onConfigChanged?(config)
        log("Dictation punctuation: \(config.punctuationEnabled)")
    }

    @objc private func filePunctuationToggled() {
        config.filePunctuationEnabled = (filePunctuationCheckbox.state == .on)
        config.save()
        onConfigChanged?(config)
        log("File punctuation: \(config.filePunctuationEnabled)")
    }

    @objc private func launchAtLoginToggled() {
        config.launchAtLogin = (launchAtLoginCheckbox.state == .on)
        config.save()
        onConfigChanged?(config)
        log("Launch at Login: \(config.launchAtLogin)")
    }

    public func updateConfig(_ config: Config) {
        self.config = config
        hotkeyField?.keyCode = config.hotkeyKeyCode
        hotkeyField?.modifiers = config.hotkeyModifiers
        hotkeyField?.updateDisplay()
        launchAtLoginCheckbox?.state = config.launchAtLogin ? .on : .off
        logTranscriptionsCheckbox?.state = config.logTranscriptions ? .on : .off
        punctuationCheckbox?.state = config.punctuationEnabled ? .on : .off
        filePunctuationCheckbox?.state = config.filePunctuationEnabled ? .on : .off
    }

    // MARK: - NSWindowDelegate
    public func windowWillClose(_ notification: Notification) {
        // Nothing special needed
    }
}

// MARK: - HotkeyRecorderField

/// A custom NSView that captures a key combination when clicked.
/// Shows the current hotkey, enters recording mode on click,
/// captures the next key+modifier combo (or Fn alone), then exits recording mode.
class HotkeyRecorderField: NSView {
    var keyCode: UInt16 = 18
    var modifiers: [String] = ["ctrl"]
    var onHotkeyChanged: ((_ keyCode: UInt16, _ modifiers: [String]) -> Void)?

    private var isRecording = false
    private var displayLabel: NSTextField!
    private var keyMonitor: Any?
    private var flagsMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        updateAppearance()

        displayLabel = NSTextField(labelWithString: "")
        displayLabel.frame = bounds.insetBy(dx: 8, dy: 4)
        displayLabel.autoresizingMask = [.width, .height]
        displayLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        displayLabel.alignment = .center
        addSubview(displayLabel)

        updateDisplay()
    }

    private func updateAppearance() {
        if isRecording {
            layer?.borderColor = NSColor.systemBlue.cgColor
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.1).cgColor
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    func updateDisplay() {
        if isRecording {
            displayLabel.stringValue = "Press a key combo or Fn\u{2026}"
            displayLabel.textColor = .systemBlue
        } else {
            displayLabel.stringValue = hotkeyDescription()
            displayLabel.textColor = .labelColor
        }
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        updateDisplay()

        // Monitor keyDown for modifier+key combos
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecording else { return event }

            // Escape cancels
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }

            // Require at least one modifier (don't allow bare keys)
            let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
            guard !flags.isEmpty else { return nil }

            // Capture the combo
            self.keyCode = event.keyCode
            self.modifiers = KeyMap.modifierStrings(from: flags)
            self.stopRecording()
            self.onHotkeyChanged?(self.keyCode, self.modifiers)
            return nil
        }

        // Monitor flagsChanged for Fn key alone
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self, self.isRecording else { return event }

            // Detect Fn key release (keyCode 63, fn flag gone = key was tapped)
            if event.keyCode == KeyMap.fnKeyCode {
                let hasFn = event.modifierFlags.contains(.function)
                if !hasFn {
                    // Fn was pressed and released — capture it
                    self.keyCode = KeyMap.fnKeyCode
                    self.modifiers = []
                    self.stopRecording()
                    self.onHotkeyChanged?(self.keyCode, self.modifiers)
                    return nil
                }
            }
            return event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        updateDisplay()
    }

    private func hotkeyDescription() -> String {
        KeyMap.hotkeyDescription(keyCode: keyCode, modifiers: modifiers)
    }
}
