import AppKit
import Foundation

/// Window that shows model download progress on first launch.
/// Appears before the splash screen if any required models are missing.
public class ModelDownloadWindowController {
    private var window: NSWindow?
    private var overallProgress: NSProgressIndicator!
    private var overallLabel: NSTextField!
    private var speedLabel: NSTextField!
    private var cancelButton: NSButton!
    private var retryButton: NSButton!
    private var errorLabel: NSTextField!

    private var rowViews: [ModelRowView] = []

    private var modelManager: ModelManager?
    private var models: [ModelAsset] = []
    private var completion: ((Bool) -> Void)?

    // Speed calculation
    private var lastSpeedBytes: Int64 = 0
    private var lastSpeedTime: Date = Date()
    private var rollingSpeed: Double = 0  // bytes/sec

    public init() {}

    /// Show the download window and start downloading the given models.
    /// Calls `completion(true)` when all done, `completion(false)` on cancel/fatal error.
    public func show(models: [ModelAsset], completion: @escaping (Bool) -> Void) {
        self.models = models
        self.completion = completion

        createWindow()

        // Check disk space first (need models + overhead for zip extraction)
        let needed = models.reduce(Int64(0)) { $0 + $1.expectedSize } + 500_000_000  // +500MB overhead
        if !ModelManager.checkDiskSpace(needed: needed) {
            showError("download.disk_space".localized(
                formatBytes(needed),
                formatBytes(0) // simplified — real available shown in error
            ))
            return
        }

        startDownload()
    }

    // MARK: - Window creation

    private func createWindow() {
        let width: CGFloat = 440
        let rowHeight: CGFloat = 36
        let rowsHeight = CGFloat(models.count) * rowHeight
        let height: CGFloat = 180 + rowsHeight

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

        var y = height - 44

        // Title
        let title = NSTextField(labelWithString: "download.title".localized)
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: y, width: width, height: 24)
        content.addSubview(title)
        y -= 22

        // Subtitle
        let subtitle = NSTextField(labelWithString: "download.subtitle".localized)
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 20, y: y, width: width - 40, height: 16)
        content.addSubview(subtitle)
        y -= 28

        // Model rows
        for model in models {
            let row = ModelRowView(
                frame: NSRect(x: 30, y: y - rowHeight + 8, width: width - 60, height: rowHeight),
                asset: model
            )
            content.addSubview(row)
            rowViews.append(row)
            y -= rowHeight
        }
        y -= 12

        // Overall progress bar
        overallProgress = NSProgressIndicator(frame: NSRect(x: 30, y: y, width: width - 60, height: 6))
        overallProgress.style = .bar
        overallProgress.isIndeterminate = false
        overallProgress.minValue = 0
        overallProgress.maxValue = 100
        overallProgress.doubleValue = 0
        content.addSubview(overallProgress)
        y -= 20

        // Progress label and speed
        overallLabel = NSTextField(labelWithString: "0 MB / \(formatBytes(ModelManager.totalDownloadSize))")
        overallLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        overallLabel.textColor = .secondaryLabelColor
        overallLabel.frame = NSRect(x: 30, y: y, width: 200, height: 16)
        content.addSubview(overallLabel)

        speedLabel = NSTextField(labelWithString: "")
        speedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.alignment = .right
        speedLabel.frame = NSRect(x: width - 180, y: y, width: 150, height: 16)
        content.addSubview(speedLabel)
        y -= 24

        // Error label (hidden by default)
        errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.frame = NSRect(x: 30, y: y - 10, width: width - 60, height: 32)
        errorLabel.isHidden = true
        content.addSubview(errorLabel)

        // Cancel button
        cancelButton = NSButton(title: "download.cancel".localized, target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: width / 2 - 50, y: 14, width: 100, height: 28)
        content.addSubview(cancelButton)

        // Retry button (hidden by default)
        retryButton = NSButton(title: "download.retry".localized, target: self, action: #selector(retryTapped))
        retryButton.bezelStyle = .rounded
        retryButton.frame = NSRect(x: width / 2 - 50, y: 14, width: 100, height: 28)
        retryButton.isHidden = true
        content.addSubview(retryButton)

        self.window = window
        NSApp.showDock()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Download orchestration

    private func startDownload() {
        modelManager = ModelManager()
        lastSpeedTime = Date()
        lastSpeedBytes = 0

        modelManager?.download(
            models: models,
            progress: { [weak self] progress in
                self?.updateProgress(progress)
            },
            completion: { [weak self] result in
                switch result {
                case .success:
                    self?.downloadComplete()
                case .failure(let error):
                    if case ModelDownloadError.cancelled = error {
                        // User cancelled — do nothing, completion(false) already called
                    } else {
                        self?.showError(error.localizedDescription)
                    }
                }
            }
        )
    }

    private func updateProgress(_ progress: DownloadProgress) {
        // Update row states
        for (i, row) in rowViews.enumerated() {
            if i < progress.currentIndex {
                row.setState(.done)
            } else if i == progress.currentIndex {
                let pct = progress.fileTotalBytes > 0
                    ? Double(progress.fileBytesWritten) / Double(progress.fileTotalBytes)
                    : 0
                row.setState(.downloading(pct))
            } else {
                row.setState(.pending)
            }
        }

        // Overall progress
        let overallTotal = progress.overallTotalBytes
        let pct = overallTotal > 0
            ? Double(progress.overallBytesWritten) / Double(overallTotal) * 100
            : 0
        overallProgress.doubleValue = pct

        overallLabel.stringValue = "\(formatBytes(progress.overallBytesWritten)) / \(formatBytes(overallTotal))"

        // Speed (rolling average)
        let now = Date()
        let dt = now.timeIntervalSince(lastSpeedTime)
        if dt >= 1.0 {
            let db = Double(progress.overallBytesWritten - lastSpeedBytes)
            let instantSpeed = db / dt
            rollingSpeed = rollingSpeed * 0.5 + instantSpeed * 0.5
            lastSpeedBytes = progress.overallBytesWritten
            lastSpeedTime = now
            speedLabel.stringValue = "\(formatBytes(Int64(rollingSpeed)))/s"
        }
    }

    private func downloadComplete() {
        // Mark all rows as done
        for row in rowViews {
            row.setState(.done)
        }
        overallProgress.doubleValue = 100
        overallLabel.stringValue = "download.complete".localized
        speedLabel.stringValue = ""

        log("All models downloaded — proceeding to app startup", tag: "ModelDownload")

        // Brief pause to show "complete" state, then proceed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.close()
            self?.completion?(true)
        }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        cancelButton.isHidden = true
        retryButton.isHidden = false
        log("Download error shown: \(message)", tag: "ModelDownload")
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        modelManager?.cancel()
        close()
        completion?(false)
    }

    @objc private func retryTapped() {
        errorLabel.isHidden = true
        retryButton.isHidden = true
        cancelButton.isHidden = false

        // Re-check which models are still missing
        models = ModelManager.missingModels()
        if models.isEmpty {
            downloadComplete()
            return
        }

        // Reset row states
        for row in rowViews {
            row.setState(.pending)
        }
        overallProgress.doubleValue = 0
        speedLabel.stringValue = ""

        startDownload()
    }

    private func close() {
        window?.close()
        window = nil
        NSApp.hideDockIfNoWindows()
    }
}

// MARK: - ModelRowView

/// A single row in the download window showing one model's status.
private class ModelRowView: NSView {

    enum State {
        case pending
        case downloading(Double)  // 0.0 ... 1.0
        case done
        case error
    }

    private let statusIcon: NSTextField
    private let nameLabel: NSTextField
    private let sizeLabel: NSTextField
    private let fileProgress: NSProgressIndicator

    init(frame: NSRect, asset: ModelAsset) {
        statusIcon = NSTextField(labelWithString: "○")
        nameLabel = NSTextField(labelWithString: asset.displayName.localized)
        sizeLabel = NSTextField(labelWithString: asset.displaySize)
        fileProgress = NSProgressIndicator()

        super.init(frame: frame)

        statusIcon.font = NSFont.systemFont(ofSize: 12)
        statusIcon.textColor = .tertiaryLabelColor
        statusIcon.frame = NSRect(x: 0, y: (frame.height - 16) / 2, width: 20, height: 16)
        addSubview(statusIcon)

        nameLabel.font = NSFont.systemFont(ofSize: 12)
        nameLabel.frame = NSRect(x: 24, y: (frame.height - 16) / 2, width: 200, height: 16)
        addSubview(nameLabel)

        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right
        sizeLabel.frame = NSRect(x: frame.width - 70, y: (frame.height - 16) / 2, width: 70, height: 16)
        addSubview(sizeLabel)

        fileProgress.style = .bar
        fileProgress.isIndeterminate = false
        fileProgress.minValue = 0
        fileProgress.maxValue = 1
        fileProgress.doubleValue = 0
        fileProgress.frame = NSRect(x: 24, y: 2, width: frame.width - 94, height: 4)
        fileProgress.isHidden = true
        addSubview(fileProgress)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func setState(_ state: State) {
        switch state {
        case .pending:
            statusIcon.stringValue = "○"
            statusIcon.textColor = .tertiaryLabelColor
            nameLabel.textColor = .secondaryLabelColor
            fileProgress.isHidden = true
        case .downloading(let pct):
            statusIcon.stringValue = "◉"
            statusIcon.textColor = .systemBlue
            nameLabel.textColor = .labelColor
            fileProgress.isHidden = false
            fileProgress.doubleValue = pct
        case .done:
            statusIcon.stringValue = "✓"
            statusIcon.textColor = .systemGreen
            nameLabel.textColor = .secondaryLabelColor
            fileProgress.isHidden = true
        case .error:
            statusIcon.stringValue = "✗"
            statusIcon.textColor = .systemRed
            nameLabel.textColor = .systemRed
            fileProgress.isHidden = true
        }
    }
}

// MARK: - Formatting helpers

private func formatBytes(_ bytes: Int64) -> String {
    if bytes >= 1_073_741_824 {
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    } else if bytes >= 1_048_576 {
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    } else {
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
