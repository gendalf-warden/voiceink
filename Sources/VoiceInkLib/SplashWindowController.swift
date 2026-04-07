import AppKit
import Foundation

/// Splash window shown during app startup with progress milestones
public class SplashWindowController {
    private var window: NSWindow?
    private var progressBar: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var milestoneLabels: [NSTextField] = []

    private let milestones = [
        "Loading config...",
        "Starting Whisper server...",
        "Starting LLM...",
        "Checking permissions...",
        "Ready!",
    ]

    public init() {}

    public func show() {
        let width: CGFloat = 300
        let height: CGFloat = 220

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

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = contentView

        // App name
        let title = NSTextField(labelWithString: "VoiceInk")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: height - 50, width: width, height: 30)
        contentView.addSubview(title)

        // Subtitle
        let subtitle = NSTextField(labelWithString: "Voice dictation loading...")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 0, y: height - 68, width: width, height: 16)
        contentView.addSubview(subtitle)

        // Progress bar
        progressBar = NSProgressIndicator(frame: NSRect(x: 30, y: height - 98, width: width - 60, height: 6))
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = Double(milestones.count)
        progressBar.doubleValue = 0
        contentView.addSubview(progressBar)

        // Milestone labels
        let startY = height - 125
        for (i, text) in milestones.enumerated() {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            label.frame = NSRect(x: 40, y: startY - CGFloat(i) * 20, width: width - 60, height: 16)
            contentView.addSubview(label)
            milestoneLabels.append(label)
        }

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Update progress to a specific milestone (0-based index)
    public func setMilestone(_ index: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.progressBar?.doubleValue = Double(index + 1)

            for (i, label) in self.milestoneLabels.enumerated() {
                if i < index {
                    label.textColor = .secondaryLabelColor
                    label.stringValue = "✓ " + self.milestones[i].replacingOccurrences(of: "...", with: "")
                } else if i == index {
                    label.textColor = .labelColor
                    label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                } else {
                    label.textColor = .tertiaryLabelColor
                }
            }
        }
    }

    /// Close splash immediately
    public func close() {
        let win = self.window
        self.window = nil
        if Thread.isMainThread {
            win?.close()
        } else {
            DispatchQueue.main.async {
                win?.close()
            }
        }
    }
}
