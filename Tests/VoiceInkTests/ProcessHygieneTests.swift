import XCTest
@testable import VoiceInkLib

/// Tests for `ProcessHygiene.parseOrphanPIDs` — the parsing logic for `ps -axo
/// pid=,command=` output. The full kill flow can't be unit-tested (it spawns
/// real processes and sends real signals), but the parse step is pure and
/// catches the bug classes that matter: wrong PID, wrong process, own PID
/// caught by mistake, partial path match.
final class ProcessHygieneTests: XCTestCase {

    private let bundledWhisper = "/Applications/VoiceInk.app/Contents/Resources/whisper-server"
    private let unrelated = "/usr/local/bin/whisper-server"  // homebrew, NOT ours

    func testFindsBundledWhisperServer() {
        let ps = """
          12345 \(bundledWhisper) -m /path/to/model --port 8178
          12346 /bin/bash
          12347 /Applications/Safari.app/Contents/MacOS/Safari
        """
        let pids = ProcessHygiene.parseOrphanPIDs(
            psOutput: ps, executablePath: bundledWhisper, ownPID: 99999
        )
        XCTAssertEqual(pids, [12345])
    }

    func testFindsMultipleOrphans() {
        let ps = """
          100 \(bundledWhisper) -m model1
          200 \(bundledWhisper) -m model2
          300 /bin/zsh
          400 \(bundledWhisper) -m model3
        """
        let pids = ProcessHygiene.parseOrphanPIDs(
            psOutput: ps, executablePath: bundledWhisper, ownPID: 99999
        )
        XCTAssertEqual(pids.sorted(), [100, 200, 400])
    }

    func testSkipsOwnPID() {
        // Must never kill ourselves — even if by some quirk our own process
        // matched the executable path (shouldn't, but defense in depth).
        let ps = """
          12345 \(bundledWhisper) -m model
          77777 /Applications/VoiceInk.app/Contents/MacOS/voiceink
        """
        let pids = ProcessHygiene.parseOrphanPIDs(
            psOutput: ps, executablePath: bundledWhisper, ownPID: 12345
        )
        XCTAssertTrue(pids.isEmpty)
    }

    func testIgnoresHomebrewOrSystemBinaryWithSameName() {
        // We must NOT kill a homebrew-installed whisper-server (or any other
        // binary with that filename) — only OUR bundled one.
        let ps = """
          1000 \(unrelated) --port 9000
          1001 /opt/homebrew/bin/whisper-server --serve
        """
        let pids = ProcessHygiene.parseOrphanPIDs(
            psOutput: ps, executablePath: bundledWhisper, ownPID: 99999
        )
        XCTAssertTrue(pids.isEmpty)
    }

    func testMatchesExactExecutableWithNoArgs() {
        // Some orphans launched without args still appear with just the path.
        let ps = """
          5000 \(bundledWhisper)
        """
        let pids = ProcessHygiene.parseOrphanPIDs(
            psOutput: ps, executablePath: bundledWhisper, ownPID: 99999
        )
        XCTAssertEqual(pids, [5000])
    }

    func testRejectsPrefixSubstringMatch() {
        // A binary whose path is `/Applications/VoiceInk.app/Contents/Resources/whisper-server-experimental`
        // must not match `/Applications/VoiceInk.app/Contents/Resources/whisper-server`.
        let almost = bundledWhisper + "-experimental"
        let ps = """
          6000 \(almost) -m foo
        """
        let pids = ProcessHygiene.parseOrphanPIDs(
            psOutput: ps, executablePath: bundledWhisper, ownPID: 99999
        )
        XCTAssertTrue(pids.isEmpty, "prefix substring should NOT match — bug nest")
    }

    func testHandlesLeadingWhitespaceInPSOutput() {
        // `ps -axo pid=` right-aligns the PID column to its widest value, so
        // shorter PIDs come with leading whitespace.
        let ps = """
              12 \(bundledWhisper)
            1234 \(bundledWhisper) -m model
          567890 \(bundledWhisper)
        """
        let pids = ProcessHygiene.parseOrphanPIDs(
            psOutput: ps, executablePath: bundledWhisper, ownPID: 99999
        )
        XCTAssertEqual(pids.sorted(), [12, 1234, 567890])
    }

    func testEmptyOutput() {
        XCTAssertEqual(
            ProcessHygiene.parseOrphanPIDs(psOutput: "", executablePath: bundledWhisper, ownPID: 1),
            []
        )
    }

    func testIgnoresMalformedLines() {
        let ps = """
          abc not-a-pid line
          \(bundledWhisper) no-pid
          12345 \(bundledWhisper) -m model
        """
        let pids = ProcessHygiene.parseOrphanPIDs(
            psOutput: ps, executablePath: bundledWhisper, ownPID: 99999
        )
        XCTAssertEqual(pids, [12345])
    }
}
