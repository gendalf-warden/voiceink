import AppKit
import AVFoundation

/// First-run wizard: explains the app and guides through permission grants
public class FirstRunWindowController {
    private var window: NSWindow?
    private var contentView: NSView!
    private let width: CGFloat = 440
    private let height: CGFloat = 340
    private var onComplete: (() -> Void)?

    private var micButton: NSButton!
    private var accButton: NSButton!
    private var micStatus: NSTextField!
    private var accStatus: NSTextField!
    private var continueButton: NSButton!

    public init() {}

    public func show(completion: @escaping () -> Void) {
        self.onComplete = completion

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = content
        self.contentView = content

        var y = height - 50

        // Title
        let title = NSTextField(labelWithString: "Welcome to VoiceInk")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: y, width: width, height: 28)
        content.addSubview(title)
        y -= 24

        // Subtitle
        let subtitle = NSTextField(labelWithString: "Local voice dictation for macOS")
        subtitle.font = NSFont.systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 0, y: y, width: width, height: 18)
        content.addSubview(subtitle)
        y -= 36

        // Description
        let desc = NSTextField(wrappingLabelWithString:
            "VoiceInk needs two permissions to work. Press the hotkey to record your voice, and the text is typed into any app.")
        desc.font = NSFont.systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center
        desc.frame = NSRect(x: 30, y: y - 30, width: width - 60, height: 36)
        content.addSubview(desc)
        y -= 56

        // --- Permission 1: Microphone ---
        let micIcon = NSTextField(labelWithString: "\u{1F3A4}")
        micIcon.font = NSFont.systemFont(ofSize: 22)
        micIcon.frame = NSRect(x: 30, y: y - 2, width: 30, height: 28)
        content.addSubview(micIcon)

        let micLabel = NSTextField(labelWithString: "Microphone")
        micLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        micLabel.frame = NSRect(x: 65, y: y + 2, width: 150, height: 20)
        content.addSubview(micLabel)

        let micDesc = NSTextField(labelWithString: "To hear your voice for transcription")
        micDesc.font = NSFont.systemFont(ofSize: 11)
        micDesc.textColor = .secondaryLabelColor
        micDesc.frame = NSRect(x: 65, y: y - 14, width: 250, height: 14)
        content.addSubview(micDesc)

        micStatus = NSTextField(labelWithString: "")
        micStatus.font = NSFont.systemFont(ofSize: 18)
        micStatus.alignment = .center
        micStatus.frame = NSRect(x: width - 80, y: y - 8, width: 40, height: 28)
        content.addSubview(micStatus)

        micButton = NSButton(title: "Grant", target: self, action: #selector(grantMicrophone))
        micButton.bezelStyle = .rounded
        micButton.frame = NSRect(x: width - 100, y: y - 8, width: 70, height: 28)
        content.addSubview(micButton)
        y -= 60

        // --- Permission 2: Accessibility ---
        let accIcon = NSTextField(labelWithString: "\u{2328}\u{FE0F}")
        accIcon.font = NSFont.systemFont(ofSize: 22)
        accIcon.frame = NSRect(x: 30, y: y - 2, width: 30, height: 28)
        content.addSubview(accIcon)

        let accLabel = NSTextField(labelWithString: "Accessibility")
        accLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        accLabel.frame = NSRect(x: 65, y: y + 2, width: 150, height: 20)
        content.addSubview(accLabel)

        let accDesc = NSTextField(labelWithString: "To type text and capture the hotkey")
        accDesc.font = NSFont.systemFont(ofSize: 11)
        accDesc.textColor = .secondaryLabelColor
        accDesc.frame = NSRect(x: 65, y: y - 14, width: 250, height: 14)
        content.addSubview(accDesc)

        accStatus = NSTextField(labelWithString: "")
        accStatus.font = NSFont.systemFont(ofSize: 18)
        accStatus.alignment = .center
        accStatus.frame = NSRect(x: width - 80, y: y - 8, width: 40, height: 28)
        content.addSubview(accStatus)

        accButton = NSButton(title: "Grant", target: self, action: #selector(grantAccessibility))
        accButton.bezelStyle = .rounded
        accButton.frame = NSRect(x: width - 100, y: y - 8, width: 70, height: 28)
        content.addSubview(accButton)
        y -= 56

        // Separator
        let sep = NSBox(frame: NSRect(x: 30, y: y, width: width - 60, height: 1))
        sep.boxType = .separator
        content.addSubview(sep)
        y -= 16

        // Continue button
        continueButton = NSButton(title: "Continue", target: self, action: #selector(continuePressed))
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.frame = NSRect(x: width / 2 - 55, y: y - 20, width: 110, height: 32)
        content.addSubview(continueButton)

        self.window = window
        updateStatus()
        NSApp.showDock()
        window.makeKeyAndOrderFront(nil)

        // Poll for permission changes (user grants in System Settings)
        pollPermissions()
    }

    // MARK: - Actions

    @objc private func grantMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatus()
            }
        }
    }

    @objc private func grantAccessibility() {
        // Temporarily lower window level so System Settings dialog appears on top
        window?.level = .normal
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // Restore floating after a delay to let the system dialog appear
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.window?.level = .floating
            self?.updateStatus()
        }
    }

    @objc private func continuePressed() {
        let win = self.window
        self.window = nil
        win?.close()
        // Don't call hideDockIfNoWindows() here — the next window
        // (model download or splash) will show immediately after.
        onComplete?()
    }

    // MARK: - Status

    private func updateStatus() {
        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accGranted = AXIsProcessTrusted()

        if micGranted {
            micButton.isHidden = true
            micStatus.stringValue = "\u{2705}"
        } else {
            micButton.isHidden = false
            micStatus.stringValue = ""
        }

        if accGranted {
            accButton.isHidden = true
            accStatus.stringValue = "\u{2705}"
        } else {
            accButton.isHidden = false
            accStatus.stringValue = ""
        }
    }

    private func pollPermissions() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard self?.window != nil else { return }
            self?.updateStatus()
            self?.pollPermissions()
        }
    }
}
