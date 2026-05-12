import AppKit
import Carbon
import Foundation

public class TextInserter {
    /// Length of last inserted text (including trailing space) for undo
    public private(set) var lastInsertedLength: Int = 0

    public init() {}

    /// Pasteboard transient marker — well-known type that asks clipboard managers
    /// (Maccy, Paste, Raycast etc.) NOT to record this clipboard write to history.
    /// Spec: http://nspasteboard.org
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    public func insert(text: String) {
        let insertedText = text + " "
        lastInsertedLength = insertedText.count
        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let previousContents = pasteboard.string(forType: .string)

        // Set our text (trailing space so next dictation/typing continues naturally).
        // The transient marker tells clipboard managers to ignore this write —
        // dictated text shouldn't end up in their history (privacy).
        pasteboard.clearContents()
        pasteboard.setString(text + " ", forType: .string)
        pasteboard.setString("", forType: TextInserter.transientType)

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pasteboard.clearContents()
            if let previous = previousContents {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Resolve "v" keycode for current keyboard layout
        let vKeyCode: CGKeyCode = resolveKeyCode(for: "v") ?? 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func resolveKeyCode(for character: String) -> CGKeyCode? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataRef = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        let keyboardLayout = layoutData.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self) }

        for keyCode: UInt16 in 0..<128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)

            UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )

            if length > 0 {
                let s = String(utf16CodeUnits: chars, count: length)
                if s.lowercased() == character.lowercased() {
                    return CGKeyCode(keyCode)
                }
            }
        }

        return nil
    }

    /// Undo last insertion: select N characters backwards and delete them
    public func undoLastInsertion() {
        guard lastInsertedLength > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)

        // Shift+Left arrow N times to select inserted text
        for _ in 0..<lastInsertedLength {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: true) // Left arrow
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: false)
            keyDown?.flags = .maskShift
            keyUp?.flags = .maskShift
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }

        // Delete selected text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            let delDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true) // Delete key
            let delUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            delDown?.post(tap: .cghidEventTap)
            delUp?.post(tap: .cghidEventTap)
            log("Undo: removed \(lastInsertedLength) chars")
            lastInsertedLength = 0
        }
    }

    public static func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
