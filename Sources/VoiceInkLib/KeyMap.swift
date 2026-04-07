import AppKit
import Foundation

/// Shared key code and modifier mappings used across the app
public enum KeyMap {
    public static let fnKeyCode: UInt16 = 63

    public static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
        45: "N", 46: "M", 49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
        53: "Escape", 63: "Fn", 76: "Enter",
        96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 109: "F10", 111: "F12",
        118: "F4", 120: "F2", 122: "F1",
    ]

    public static func keyName(for code: UInt16) -> String {
        keyNames[code] ?? "key(\(code))"
    }

    public static func modifierSymbols(_ modifiers: [String]) -> String {
        modifiers.map { mod -> String in
            switch mod.lowercased() {
            case "ctrl", "control": return "⌃"
            case "cmd", "command": return "⌘"
            case "opt", "option", "alt": return "⌥"
            case "shift": return "⇧"
            default: return mod
            }
        }.joined()
    }

    public static func hotkeyDescription(keyCode: UInt16, modifiers: [String]) -> String {
        if keyCode == fnKeyCode && modifiers.isEmpty {
            return "Fn"
        }
        return "\(modifierSymbols(modifiers))\(keyName(for: keyCode))"
    }

    public static func modifierStrings(from flags: NSEvent.ModifierFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.control) { result.append("ctrl") }
        if flags.contains(.option) { result.append("opt") }
        if flags.contains(.shift) { result.append("shift") }
        if flags.contains(.command) { result.append("cmd") }
        return result
    }
}
