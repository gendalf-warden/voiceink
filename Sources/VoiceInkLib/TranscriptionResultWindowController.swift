import AppKit
import Foundation

/// Window that shows file transcription progress and streams chunks as they arrive.
/// Supports: timestamp toggle, Copy, Save as TXT/SRT/MD, live stats.
public class TranscriptionResultWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var statusLabel: NSTextField!
    private var statsLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var copyButton: NSButton!
    private var saveButton: NSButton!
    private var timestampsCheckbox: NSButton!

    private var chunks: [FileTranscriptionManager.ChunkResult] = []
    private var showTimestamps: Bool = false
    private var pipelineStart: Date?
    private var totalDuration: TimeInterval = 0
    private var totalChunks: Int = 0
    private var tickTimer: Timer?

    public func show() {
        if let existing = window, existing.isVisible {
            NSApp.showDock()
            existing.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let width: CGFloat = 640
        let height: CGFloat = 480

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
        window.minSize = NSSize(width: 480, height: 320)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // Status label (top)
        statusLabel = NSTextField(labelWithString: "Preparing...")
        statusLabel.frame = NSRect(x: 16, y: height - 32, width: width - 32, height: 18)
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(statusLabel)

        // Progress bar
        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.frame = NSRect(x: 16, y: height - 52, width: width - 32, height: 8)
        progressBar.autoresizingMask = [.width, .minYMargin]
        progressBar.startAnimation(nil)
        contentView.addSubview(progressBar)

        // Text view (scrollable)
        scrollView = NSScrollView(frame: NSRect(x: 16, y: 88, width: width - 32, height: height - 152))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = ""

        scrollView.documentView = textView
        contentView.addSubview(scrollView)

        // Stats label (below text view)
        statsLabel = NSTextField(labelWithString: "")
        statsLabel.frame = NSRect(x: 16, y: 56, width: width - 32, height: 16)
        statsLabel.font = NSFont.systemFont(ofSize: 11)
        statsLabel.textColor = .tertiaryLabelColor
        statsLabel.autoresizingMask = [.width, .maxYMargin]
        contentView.addSubview(statsLabel)

        // Timestamps checkbox
        timestampsCheckbox = NSButton(checkboxWithTitle: "Show timestamps", target: self, action: #selector(toggleTimestamps))
        timestampsCheckbox.frame = NSRect(x: 16, y: 18, width: 160, height: 20)
        timestampsCheckbox.autoresizingMask = [.maxXMargin, .maxYMargin]
        timestampsCheckbox.state = .off
        contentView.addSubview(timestampsCheckbox)

        // Save button
        saveButton = NSButton(title: "Save…", target: self, action: #selector(saveText))
        saveButton.frame = NSRect(x: width - 184, y: 12, width: 80, height: 28)
        saveButton.bezelStyle = .rounded
        saveButton.autoresizingMask = [.minXMargin, .maxYMargin]
        saveButton.isEnabled = false
        contentView.addSubview(saveButton)

        // Copy button
        copyButton = NSButton(title: "Copy", target: self, action: #selector(copyText))
        copyButton.frame = NSRect(x: width - 96, y: 12, width: 80, height: 28)
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.autoresizingMask = [.minXMargin, .maxYMargin]
        copyButton.isEnabled = false
        contentView.addSubview(copyButton)

        self.window = window
        NSApp.showDock()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel?.stringValue = text
        }
    }

    public func beginStreaming(totalChunks: Int, totalDuration: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.totalChunks = totalChunks
            self.totalDuration = totalDuration
            self.pipelineStart = Date()
            self.chunks = []
            self.progressBar?.isIndeterminate = false
            self.progressBar?.minValue = 0
            self.progressBar?.maxValue = Double(totalChunks)
            self.progressBar?.doubleValue = 0
            self.textView?.string = ""
            self.copyButton?.isEnabled = true
            self.saveButton?.isEnabled = true

            // Tick elapsed time every second
            self.tickTimer?.invalidate()
            self.tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.updateStats()
            }
        }
    }

    public func appendChunk(_ chunk: FileTranscriptionManager.ChunkResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.chunks.append(chunk)
            self.chunks.sort { $0.index < $1.index }
            self.progressBar?.doubleValue = Double(self.chunks.count)
            self.renderText()
            self.updateStats()
            // Auto-scroll to bottom
            self.textView?.scrollRangeToVisible(NSRange(location: self.textView?.string.count ?? 0, length: 0))
        }
    }

    /// Replace the text of an already-appended chunk (matched by `index`).
    /// Used by low-memory pipeline: Phase 1 streams raw ASR text, Phase 2 replaces
    /// each chunk's text with the LLM-processed version. No-op if index not found.
    public func updateChunkText(index: Int, text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let pos = self.chunks.firstIndex(where: { $0.index == index }) else { return }
            let old = self.chunks[pos]
            self.chunks[pos] = FileTranscriptionManager.ChunkResult(
                index: old.index, startTime: old.startTime, endTime: old.endTime, text: text
            )
            self.renderText()
            self.updateStats()
        }
    }

    /// Reset progress bar for a second phase (e.g. LLM post-processing after all ASR is done).
    /// Status label is left to the caller via setStatus().
    public func beginPhase(label: String, totalChunks: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusLabel?.stringValue = label
            self.progressBar?.minValue = 0
            self.progressBar?.maxValue = Double(totalChunks)
            self.progressBar?.doubleValue = 0
        }
    }

    /// Bump progress bar by one (used during phase 2 where chunks are updated in place).
    public func tickPhaseProgress() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let v = (self.progressBar?.doubleValue ?? 0) + 1
            self.progressBar?.doubleValue = v
        }
    }

    public func finishStreaming(totalTime: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tickTimer?.invalidate()
            self.tickTimer = nil
            self.progressBar?.doubleValue = Double(self.totalChunks)
            self.statusLabel?.stringValue = "Done"
            self.statusLabel?.textColor = .labelColor
            self.updateStats(finalTime: totalTime)
        }
    }

    public func setError(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.textView?.string = text
            self.progressBar?.stopAnimation(nil)
            self.progressBar?.isHidden = true
            self.statusLabel?.stringValue = "Error"
            self.statusLabel?.textColor = .systemRed
        }
    }

    /// Diagnostic: indices of chunks that came back empty (no recognized speech).
    public func emptyChunkIndices() -> [Int] {
        chunks.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { $0.index }
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

    // MARK: - Rendering

    private func renderText() {
        let text = showTimestamps ? chunksWithTimestamps() : chunksPlainText()
        textView?.string = text
    }

    /// A chunk counts as "speech" only if it has at least one non-whitespace character.
    /// Empty chunks (silence or filtered hallucinations) are hidden from formatted output —
    /// otherwise the user sees a long tail of `[1:12:34] ` lines for silent stretches.
    private func nonEmptyChunks() -> [FileTranscriptionManager.ChunkResult] {
        chunks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func chunksPlainText() -> String {
        nonEmptyChunks().map { $0.text }.joined(separator: " ")
    }

    private func chunksWithTimestamps() -> String {
        nonEmptyChunks().map { chunk in
            "[\(formatTime(chunk.startTime))] \(chunk.text)"
        }.joined(separator: "\n")
    }

    private func chunksAsSRT() -> String {
        nonEmptyChunks().enumerated().map { (i, chunk) in
            """
            \(i + 1)
            \(formatSRTTime(chunk.startTime)) --> \(formatSRTTime(chunk.endTime))
            \(chunk.text)
            """
        }.joined(separator: "\n\n")
    }

    private func chunksAsMarkdown() -> String {
        var out = "# Transcription\n\n"
        for chunk in nonEmptyChunks() {
            out += "**[\(formatTime(chunk.startTime))]** \(chunk.text)\n\n"
        }
        return out
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func formatSRTTime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - floor(seconds)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private func updateStats(finalTime: TimeInterval? = nil) {
        let text = chunksPlainText()
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let chars = text.count
        var parts: [String] = []
        parts.append("\(words) words")
        parts.append("\(chars) chars")
        let emptyCount = chunks.count - nonEmptyChunks().count
        if emptyCount > 0 {
            parts.append("\(chunks.count)/\(totalChunks) chunks (\(emptyCount) empty)")
        } else {
            parts.append("\(chunks.count)/\(totalChunks) chunks")
        }
        if totalDuration > 0 {
            parts.append("audio \(formatTime(totalDuration))")
        }
        if let finalTime = finalTime {
            parts.append("processed in \(formatElapsed(finalTime))")
            // Speed stats: realtime factor + words per second of audio
            if totalDuration > 0 {
                let rtf = totalDuration / finalTime
                parts.append(String(format: "%.1f× realtime", rtf))
            }
            if totalDuration > 0 {
                let wpm = Double(words) / totalDuration * 60
                parts.append(String(format: "%.0f words/min (audio)", wpm))
            }
        } else if let start = pipelineStart {
            let elapsed = Date().timeIntervalSince(start)
            parts.append("elapsed \(formatElapsed(elapsed))")
            // ETA: extrapolate from completed chunks
            if chunks.count > 0 && chunks.count < totalChunks {
                let avgPerChunk = elapsed / Double(chunks.count)
                let remaining = avgPerChunk * Double(totalChunks - chunks.count)
                parts.append("ETA \(formatElapsed(remaining))")
            }
        }
        statsLabel?.stringValue = parts.joined(separator: " · ")
    }

    /// Format duration as M:SS or H:MM:SS (no decimals, always minutes+seconds).
    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Actions

    @objc private func toggleTimestamps() {
        showTimestamps = (timestampsCheckbox.state == .on)
        renderText()
    }

    @objc private func copyText() {
        let text = textView?.string ?? ""
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let originalTitle = copyButton.title
        copyButton.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton?.title = originalTitle
        }
    }

    @objc private func saveText() {
        let panel = NSSavePanel()
        panel.title = "Save transcription"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcription.txt"

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 0, y: 10, width: 60, height: 20)
        accessory.addSubview(label)

        let popup = NSPopUpButton(frame: NSRect(x: 60, y: 8, width: 200, height: 24))
        popup.addItems(withTitles: ["Plain text (.txt)", "SubRip subtitles (.srt)", "Markdown (.md)"])
        accessory.addSubview(popup)
        panel.accessoryView = accessory

        popup.target = self
        popup.action = #selector(formatChanged(_:))
        objc_setAssociatedObject(popup, "panel", panel, .OBJC_ASSOCIATION_RETAIN)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content: String
        switch popup.indexOfSelectedItem {
        case 1: content = chunksAsSRT()
        case 2: content = chunksAsMarkdown()
        default: content = textView?.string ?? chunksPlainText()
        }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log("Save failed: \(error)", tag: "TranscriptionResult")
        }
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard let panel = objc_getAssociatedObject(sender, "panel") as? NSSavePanel else { return }
        let current = panel.nameFieldStringValue as NSString
        let base = current.deletingPathExtension
        let ext: String
        switch sender.indexOfSelectedItem {
        case 1: ext = "srt"
        case 2: ext = "md"
        default: ext = "txt"
        }
        panel.nameFieldStringValue = "\(base).\(ext)"
    }

    // MARK: - NSWindowDelegate
    public func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.hideDockIfNoWindows()
    }
}
