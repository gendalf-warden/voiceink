import XCTest
@testable import VoiceInkLib

/// Tests for the small bit of TextInserter that's actually unit-testable:
/// the changeCount comparator that decides whether the user's clipboard is
/// safe to restore after dictation. The rest of TextInserter (Cmd+V via
/// CGEvent, real NSPasteboard reads/writes, the 600 ms timer) is integration
/// territory and is verified manually per release.
final class TextInserterTests: XCTestCase {

    func testRestoreWhenChangeCountUnchanged() {
        // Our write bumped the count to 42. By the time the restore timer
        // fired, no one else has written, count is still 42 — safe.
        XCTAssertTrue(
            TextInserter.shouldRestoreClipboard(changeCountAtOurWrite: 42, changeCountNow: 42)
        )
    }

    func testSkipRestoreWhenUserCopiedSomethingAfter() {
        // User pressed Cmd+C in the target app after the dictated paste landed.
        // changeCount rose. Restoring would clobber their fresh copy with our
        // pre-dictation snapshot — the opposite of what they want.
        XCTAssertFalse(
            TextInserter.shouldRestoreClipboard(changeCountAtOurWrite: 42, changeCountNow: 43)
        )
        XCTAssertFalse(
            TextInserter.shouldRestoreClipboard(changeCountAtOurWrite: 42, changeCountNow: 99)
        )
    }

    func testSkipRestoreWhenCountDecreased() {
        // Shouldn't happen (changeCount is monotonic), but if some macOS quirk
        // produced it, we'd rather skip the restore than overwrite blindly.
        XCTAssertFalse(
            TextInserter.shouldRestoreClipboard(changeCountAtOurWrite: 42, changeCountNow: 41)
        )
    }

    func testEdgeCaseZero() {
        // Fresh boot, pasteboard never touched → changeCount can legitimately
        // be 0 (or very low).
        XCTAssertTrue(
            TextInserter.shouldRestoreClipboard(changeCountAtOurWrite: 0, changeCountNow: 0)
        )
    }
}
