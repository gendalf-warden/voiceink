import AppKit
import Foundation

public class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hotkeyField: HotkeyRecorderField!
    private var launchAtLoginCheckbox: NSButton!
    private var logTranscriptionsCheckbox: NSButton!
    private var dictationModePopup: NSPopUpButton!
    private var fileModePopup: NSPopUpButton!
    private var translateTargetPopup: NSPopUpButton!
    private var translateTargetLabel: NSTextField!

    private var config: Config
    public var onConfigChanged: ((Config) -> Void)?

    /// Modes shown in popups, in display order. Translate is last (visually separated).
    private let modeOrder: [PostProcessingMode] = [.off, .punctuation, .grammar, .list, .translate]

    public init(config: Config) {
        self.config = config
        super.init()
    }

    public func showWindow() {
        if let existing = window, existing.isVisible {
            NSApp.showDock()
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let width: CGFloat = 500
        let height: CGFloat = 380

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "settings.title".localized
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = contentView

        let labelWidth: CGFloat = 140  // wide enough for Russian "Горячая клавиша:"
        let checkboxLeft: CGFloat = 20 + labelWidth + 10  // = 170
        let checkboxWidth: CGFloat = width - checkboxLeft - 20

        // --- Hotkey row ---
        let hotkeyLabel = NSTextField(labelWithString: "settings.hotkey".localized)
        hotkeyLabel.frame = NSRect(x: 20, y: height - 50, width: labelWidth, height: 22)
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
        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "settings.launch_at_login".localized, target: self, action: #selector(launchAtLoginToggled))
        launchAtLoginCheckbox.frame = NSRect(x: checkboxLeft, y: height - 90, width: checkboxWidth, height: 22)
        launchAtLoginCheckbox.state = config.launchAtLogin ? .on : .off
        contentView.addSubview(launchAtLoginCheckbox)

        // --- Log transcriptions row ---
        logTranscriptionsCheckbox = NSButton(checkboxWithTitle: "settings.log_transcription".localized, target: self, action: #selector(logTranscriptionsToggled))
        logTranscriptionsCheckbox.frame = NSRect(x: checkboxLeft, y: height - 120, width: checkboxWidth, height: 22)
        logTranscriptionsCheckbox.state = config.logTranscriptions ? .on : .off
        contentView.addSubview(logTranscriptionsCheckbox)

        // --- Post-processing block ---
        let ramGB = Config.systemRAMGB
        let sectionTitle = NSTextField(labelWithString: "settings.post_processing".localized)
        sectionTitle.frame = NSRect(x: checkboxLeft, y: height - 150, width: checkboxWidth, height: 18)
        sectionTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        contentView.addSubview(sectionTitle)

        let sectionHint = NSTextField(labelWithString: "settings.post_processing.ram_hint".localized(Int64(ramGB)))
        sectionHint.frame = NSRect(x: checkboxLeft, y: height - 170, width: checkboxWidth, height: 16)
        sectionHint.font = NSFont.systemFont(ofSize: 11)
        sectionHint.textColor = .secondaryLabelColor
        contentView.addSubview(sectionHint)

        let subItemLeft = checkboxLeft + 16  // indent to show grouping
        let subLabelWidth: CGFloat = 100
        let popupWidth: CGFloat = checkboxWidth - 16 - subLabelWidth - 8

        // Dictation mode popup
        let dictationLabel = NSTextField(labelWithString: "settings.post_processing.dictation".localized)
        dictationLabel.frame = NSRect(x: subItemLeft, y: height - 199, width: subLabelWidth, height: 18)
        dictationLabel.font = NSFont.systemFont(ofSize: 12)
        contentView.addSubview(dictationLabel)

        dictationModePopup = NSPopUpButton(frame: NSRect(x: subItemLeft + subLabelWidth + 8, y: height - 204, width: popupWidth, height: 26), pullsDown: false)
        populateModePopup(dictationModePopup, selected: config.dictationMode)
        dictationModePopup.target = self
        dictationModePopup.action = #selector(dictationModeChanged)
        contentView.addSubview(dictationModePopup)

        // File mode popup
        let fileLabel = NSTextField(labelWithString: "settings.post_processing.files".localized)
        fileLabel.frame = NSRect(x: subItemLeft, y: height - 231, width: subLabelWidth, height: 18)
        fileLabel.font = NSFont.systemFont(ofSize: 12)
        contentView.addSubview(fileLabel)

        fileModePopup = NSPopUpButton(frame: NSRect(x: subItemLeft + subLabelWidth + 8, y: height - 236, width: popupWidth, height: 26), pullsDown: false)
        populateModePopup(fileModePopup, selected: config.fileMode)
        fileModePopup.target = self
        fileModePopup.action = #selector(fileModeChanged)
        contentView.addSubview(fileModePopup)

        // Translate target picker (visible only when at least one mode == .translate)
        translateTargetLabel = NSTextField(labelWithString: "settings.translate_target".localized)
        translateTargetLabel.frame = NSRect(x: subItemLeft, y: height - 263, width: subLabelWidth, height: 18)
        translateTargetLabel.font = NSFont.systemFont(ofSize: 12)
        contentView.addSubview(translateTargetLabel)

        translateTargetPopup = NSPopUpButton(frame: NSRect(x: subItemLeft + subLabelWidth + 8, y: height - 268, width: popupWidth, height: 26), pullsDown: false)
        for lang in translationTargetLanguages {
            translateTargetPopup.addItem(withTitle: lang.name)
            translateTargetPopup.item(at: translateTargetPopup.numberOfItems - 1)?.representedObject = lang.code
        }
        if let idx = translationTargetLanguages.firstIndex(where: { $0.code == config.translateTarget }) {
            translateTargetPopup.selectItem(at: idx)
        }
        translateTargetPopup.target = self
        translateTargetPopup.action = #selector(translateTargetChanged)
        contentView.addSubview(translateTargetPopup)
        updateTranslateTargetVisibility()

        // --- Hint ---
        let hint = NSTextField(wrappingLabelWithString: "settings.hotkey_hint".localized)
        hint.frame = NSRect(x: 20, y: 16, width: width - 40, height: 34)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        contentView.addSubview(hint)

        self.window = window
        NSApp.showDock()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func logTranscriptionsToggled() {
        config.logTranscriptions = (logTranscriptionsCheckbox.state == .on)
        config.save()
        onConfigChanged?(config)
        log("Log transcriptions: \(config.logTranscriptions)")
    }

    @objc private func dictationModeChanged() {
        let idx = dictationModePopup.indexOfSelectedItem
        guard idx >= 0, idx < modeOrder.count else { return }
        config.dictationMode = modeOrder[idx]
        config.save()
        onConfigChanged?(config)
        updateTranslateTargetVisibility()
        log("Dictation mode: \(config.dictationMode.rawValue)")
    }

    @objc private func fileModeChanged() {
        let idx = fileModePopup.indexOfSelectedItem
        guard idx >= 0, idx < modeOrder.count else { return }
        config.fileMode = modeOrder[idx]
        config.save()
        onConfigChanged?(config)
        updateTranslateTargetVisibility()
        log("File mode: \(config.fileMode.rawValue)")
    }

    @objc private func translateTargetChanged() {
        let idx = translateTargetPopup.indexOfSelectedItem
        guard idx >= 0, idx < translationTargetLanguages.count else { return }
        config.translateTarget = translationTargetLanguages[idx].code
        config.save()
        onConfigChanged?(config)
        log("Translate target: \(config.translateTarget)")
    }

    private func populateModePopup(_ popup: NSPopUpButton, selected: PostProcessingMode) {
        popup.removeAllItems()
        for mode in modeOrder {
            popup.addItem(withTitle: mode.localizedName)
        }
        if let idx = modeOrder.firstIndex(of: selected) {
            popup.selectItem(at: idx)
        }
    }

    private func updateTranslateTargetVisibility() {
        let needed = config.dictationMode == .translate || config.fileMode == .translate
        translateTargetLabel?.isHidden = !needed
        translateTargetPopup?.isHidden = !needed
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
        if let popup = dictationModePopup, let idx = modeOrder.firstIndex(of: config.dictationMode) {
            popup.selectItem(at: idx)
        }
        if let popup = fileModePopup, let idx = modeOrder.firstIndex(of: config.fileMode) {
            popup.selectItem(at: idx)
        }
        if let popup = translateTargetPopup,
           let idx = translationTargetLanguages.firstIndex(where: { $0.code == config.translateTarget }) {
            popup.selectItem(at: idx)
        }
        updateTranslateTargetVisibility()
    }

    // MARK: - NSWindowDelegate
    public func windowWillClose(_ notification: Notification) {
        NSApp.hideDockIfNoWindows()
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
