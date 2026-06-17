import Darwin
import Foundation

/// Kills orphaned child processes from previous app sessions.
///
/// VoiceInk launches whisper-server and llama-server as `Process` children. When
/// the app exits via `NSApplication.terminate(_)` from a code path that doesn't
/// run `AppDelegate.shutdown()` — SIGTERM/SIGINT at logout, the Uninstall flow's
/// terminate call, a crash, force-quit, jetsam OOM-kill — those children are
/// reparented to launchd and keep running. Each one holds ~600 MB; on an 8 GB
/// Mac with heavy dictation use, users have seen 3+ orphans accumulate.
///
/// Worse: only one process can bind `:8178` (no SO_REUSEPORT), so a stale
/// orphan continues serving HTTP 200 to `waitForServer()`, the freshly spawned
/// server silently fails to bind and exits, and the app ends up driving the
/// stale orphan while the watchdog restarts the wrong process.
///
/// This module sweeps orphans at app launch — the only place that's safe,
/// since by definition we hold no live children yet. It must NOT run during
/// in-session watchdog/proactive restarts (Transcriber.swift has its own
/// orchestration there).
///
/// Parsing logic is split out (`parseOrphanPIDs`) for unit testability without
/// spawning real processes.
public enum ProcessHygiene {

    /// Kill any process whose executable path matches `executablePath`, except
    /// for the current process. Also kills any process holding `port` (catches
    /// the corner case where ps output is truncated or the executable is symlinked).
    /// SIGKILL — these processes are already orphans, no graceful shutdown to wait for.
    public static func killOrphans(executablePath: String, port: Int, label: String) {
        let killedByName = killByExecutablePath(executablePath, label: label)
        let killedByPort = killByPort(port, executablePath: executablePath, label: label, alreadyKilled: killedByName)
        let total = killedByName.count + killedByPort.count
        if total == 0 {
            log("No orphan \(label) processes found", tag: "Hygiene")
        } else {
            log("Killed \(total) orphan \(label) process(es): \(killedByName + killedByPort)", tag: "Hygiene")
        }
    }

    // MARK: - Killing by executable path

    private static func killByExecutablePath(_ executablePath: String, label: String) -> [pid_t] {
        // `ps -axo pid=,command=` lists every process with no header. `command`
        // (not `comm`) gives the full path; `comm` truncates to 16 chars.
        guard let output = runPS() else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = parseOrphanPIDs(psOutput: output, executablePath: executablePath, ownPID: ownPID)
        for pid in pids {
            log("Killing orphan \(label) pid=\(pid) (matched executable path)", tag: "Hygiene")
            kill(pid, SIGKILL)
        }
        return pids
    }

    /// Parse `ps -axo pid=,command=` output and return PIDs whose command line
    /// starts with the given `executablePath`, excluding `ownPID`. Pure function
    /// for unit testability.
    public static func parseOrphanPIDs(
        psOutput: String,
        executablePath: String,
        ownPID: Int32
    ) -> [pid_t] {
        var pids: [pid_t] = []
        for rawLine in psOutput.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Format: "  12345 /path/to/binary --arg ..."
            // PID and command separated by whitespace; the rest may contain spaces.
            guard let spaceIdx = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let pidStr = String(line[line.startIndex..<spaceIdx])
            guard let pidInt = Int32(pidStr), pidInt != ownPID else { continue }
            let command = line[line.index(after: spaceIdx)...].trimmingCharacters(in: .whitespaces)
            // Match: the command starts with the bundled executable path (followed by
            // a space, end-of-string, or NUL). This avoids matching unrelated binaries
            // whose path happens to contain ours as a substring.
            if command == executablePath
                || command.hasPrefix(executablePath + " ")
                || command.hasPrefix(executablePath + "\t") {
                pids.append(pidInt)
            }
        }
        return pids
    }

    private static func runPS() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            log("ps invocation failed: \(error)", tag: "Hygiene")
            return nil
        }
    }

    // MARK: - Killing by port

    private static func killByPort(_ port: Int, executablePath: String, label: String, alreadyKilled: [pid_t]) -> [pid_t] {
        guard let output = runLsof(port: port) else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var pids: [pid_t] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let pid = pid_t(line), pid != ownPID, !alreadyKilled.contains(pid) else { continue }
            // Security (SECURITY.md L1): only SIGKILL if this PID's executable is
            // actually our bundled server. Never kill an unrelated process that
            // merely happens to hold the port (port collision / dev server).
            guard let path = resolvedExecutablePath(forPID: pid), pathsMatch(path, executablePath) else {
                log("Port \(port) held by pid=\(pid) but its executable doesn't match \(label) — skipping", tag: "Hygiene")
                continue
            }
            log("Killing process pid=\(pid) holding port \(port) (\(label), path-verified)", tag: "Hygiene")
            kill(pid, SIGKILL)
            pids.append(pid)
        }
        return pids
    }

    /// Resolve a PID's on-disk executable path via libproc. Returns nil if the
    /// process is gone or the path can't be read.
    private static func resolvedExecutablePath(forPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Symlink-resolved equality of two executable paths. Empty paths never match
    /// (so an undetected/blank bundled path can't accidentally authorize a kill).
    private static func pathsMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return URL(fileURLWithPath: a).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    private static func runLsof(port: Int) -> String? {
        // `lsof -ti :PORT` outputs one PID per line, holders of TCP/UDP `port`.
        // Returns non-zero exit if no holders — that's fine, treat as empty.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", ":\(port)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            // lsof might not be at the expected path on exotic systems; ignore.
            return nil
        }
    }
}
