import Foundation

public final class Logger {
    public static let shared = Logger()

    public let logFile: URL

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.voiceink.logger", qos: .utility)

    private init() {
        let logDir = Config.configDir
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        logFile = logDir.appendingPathComponent("voiceink.log")

        // Owner-only perms (SECURITY.md L3): the log may contain dictation text
        // when the `logTranscriptions` opt-in is on, plus usage metadata otherwise.
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o600]

        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: ownerOnly)
        } else {
            // Tighten perms on a log written by an older (0644) build.
            try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: logFile.path)
        }

        // Rotate if > 1MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64, size > 1_000_000 {
            let backup = logDir.appendingPathComponent("voiceink.log.old")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: logFile, to: backup)
            FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: ownerOnly)
        }

        fileHandle = FileHandle(forWritingAtPath: logFile.path)
        fileHandle?.seekToEndOfFile()
    }

    public func log(_ message: String, tag: String = "VoiceInk") {
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(tag)] \(message)\n"

        // Print to stdout (terminal)
        print(line, terminator: "")

        // Write to file
        queue.async { [weak self] in
            if let data = line.data(using: .utf8) {
                self?.fileHandle?.write(data)
            }
        }
    }

    deinit {
        fileHandle?.closeFile()
    }
}

/// Convenience global function
public func log(_ message: String, tag: String = "VoiceInk") {
    Logger.shared.log(message, tag: tag)
}
