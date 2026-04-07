import XCTest
@testable import VoiceInkLib

final class AppStateTests: XCTestCase {

    // MARK: - description

    func testDescriptions() {
        XCTAssertEqual(AppState.idle.description, "Ready")
        XCTAssertEqual(AppState.recording.description, "Recording...")
        XCTAssertEqual(AppState.transcribing.description, "Transcribing...")
        XCTAssertEqual(AppState.postProcessing.description, "Processing...")
        XCTAssertEqual(AppState.error("test").description, "Error: test")
    }

    // MARK: - Equatable

    func testEquatableSimpleCases() {
        XCTAssertEqual(AppState.idle, AppState.idle)
        XCTAssertEqual(AppState.recording, AppState.recording)
        XCTAssertNotEqual(AppState.idle, AppState.recording)
    }

    func testEquatableError() {
        XCTAssertEqual(AppState.error("a"), AppState.error("a"))
        XCTAssertNotEqual(AppState.error("a"), AppState.error("b"))
        XCTAssertNotEqual(AppState.error("a"), AppState.idle)
    }
}
