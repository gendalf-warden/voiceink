import XCTest
@testable import VoiceInkLib

final class KeyMapTests: XCTestCase {

    // MARK: - keyName(for:)

    func testKeyNameKnownCodes() {
        XCTAssertEqual(KeyMap.keyName(for: 0), "A")
        XCTAssertEqual(KeyMap.keyName(for: 1), "S")
        XCTAssertEqual(KeyMap.keyName(for: 49), "Space")
        XCTAssertEqual(KeyMap.keyName(for: 36), "Return")
        XCTAssertEqual(KeyMap.keyName(for: 63), "Fn")
        XCTAssertEqual(KeyMap.keyName(for: 122), "F1")
    }

    func testKeyNameUnknownCode() {
        XCTAssertEqual(KeyMap.keyName(for: 999), "key(999)")
    }

    // MARK: - modifierSymbols(_:)

    func testModifierSymbolsSingle() {
        XCTAssertEqual(KeyMap.modifierSymbols(["ctrl"]), "⌃")
        XCTAssertEqual(KeyMap.modifierSymbols(["cmd"]), "⌘")
        XCTAssertEqual(KeyMap.modifierSymbols(["opt"]), "⌥")
        XCTAssertEqual(KeyMap.modifierSymbols(["shift"]), "⇧")
    }

    func testModifierSymbolsAliases() {
        XCTAssertEqual(KeyMap.modifierSymbols(["control"]), "⌃")
        XCTAssertEqual(KeyMap.modifierSymbols(["command"]), "⌘")
        XCTAssertEqual(KeyMap.modifierSymbols(["option"]), "⌥")
        XCTAssertEqual(KeyMap.modifierSymbols(["alt"]), "⌥")
    }

    func testModifierSymbolsMultiple() {
        XCTAssertEqual(KeyMap.modifierSymbols(["ctrl", "cmd"]), "⌃⌘")
        XCTAssertEqual(KeyMap.modifierSymbols(["shift", "opt", "cmd"]), "⇧⌥⌘")
    }

    func testModifierSymbolsEmpty() {
        XCTAssertEqual(KeyMap.modifierSymbols([]), "")
    }

    func testModifierSymbolsUnknown() {
        XCTAssertEqual(KeyMap.modifierSymbols(["foo"]), "foo")
    }

    // MARK: - hotkeyDescription(keyCode:modifiers:)

    func testHotkeyDescriptionFnOnly() {
        XCTAssertEqual(KeyMap.hotkeyDescription(keyCode: 63, modifiers: []), "Fn")
    }

    func testHotkeyDescriptionModifierPlusKey() {
        XCTAssertEqual(KeyMap.hotkeyDescription(keyCode: 0, modifiers: ["cmd"]), "⌘A")
        XCTAssertEqual(KeyMap.hotkeyDescription(keyCode: 49, modifiers: ["ctrl", "shift"]), "⌃⇧Space")
    }

    func testHotkeyDescriptionFnWithModifiers() {
        // Fn + modifier is not "Fn" shortcut — should show full description
        XCTAssertEqual(KeyMap.hotkeyDescription(keyCode: 63, modifiers: ["cmd"]), "⌘Fn")
    }

    // MARK: - fnKeyCode

    func testFnKeyCode() {
        XCTAssertEqual(KeyMap.fnKeyCode, 63)
    }
}
