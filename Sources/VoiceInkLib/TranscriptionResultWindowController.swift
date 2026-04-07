import AppKit
import Foundation

/// Window that shows file transcription progress and result
public class TranscriptionResultWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var copyButton: NSButton!

    public func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let width: CGFloat = 560
        let height: CGFloat = 420

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "File Transcription"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.minSize = NSSize(width: 360, height: 260)

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // Status row (spinner + label)
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 16, y: height - 36, width: 18, height: 18)
        spinner.autoresizingMask = [.maxXMargin, .minYMargin]
        spinner.startAnimation(nil)
        contentView.addSubview(spinner)

        statusLabel = NSTextField(labelWithString: "Preparing...")
        statusLabel.frame = NSRect(x: 40, y: height - 38, width: width - 56, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(statusLabel)

        // Text view in scroll view
        scrollView = NSScrollView(frame: NSRect(x: 16, y: 52, width: width - 32, height: height - 92))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = ""

        scrollView.documentView = textView
        contentView.addSubview(scrollView)

        // Copy button
        copyButton = NSButton(title: "Copy", target: self, action: #selector(copyText))
        copyButton.frame = NSRect(x: width - 96, y: 12, width: 80, height: 28)
        copyButton.bezelStyle = .rounded
        copyButton.autoresizingMask = [.minXMargin, .maxYMargin]
        copyButton.isEnabled = false
        contentView.addSubview(copyButton)

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel?.stringValue = text
        }
    }

    public func setResult(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.textView?.string = text
            self.spinner?.stopAnimation(nil)
            self.spinner?.isHidden = true
            self.copyButton?.isEnabled = true
            self.statusLabel?.stringValue = "Done"
            self.statusLabel?.textColor = .labelColor
        }
    }

    public func setError(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.textView?.string = text
            self.spinner?.stopAnimation(nil)
            self.spinner?.isHidden = true
            self.statusLabel?.stringValue = "Error"
            self.statusLabel?.textColor = .systemRed
        }
    }

    public func close() {
        let win = self.window
        self.window = nil
        if Thread.isMainThread {
            win?.close()
        } else {
            DispatchQueue.main.async { win?.close() }
        }
    }

    @objc private func copyText() {
        guard let text = textView?.string, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Visual feedback
        let originalTitle = copyButton.title
        copyButton.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyButton?.title = originalTitle
        }
    }

    // MARK: - NSWindowDelegate
    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
