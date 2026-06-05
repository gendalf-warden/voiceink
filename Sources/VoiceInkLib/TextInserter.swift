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

    /// Delay before restoring the user's previous clipboard contents.
    /// Was 150 ms — too short under memory pressure or in heavy apps (the target
    /// app hadn't consumed the paste yet, so the restore raced ahead and the
    /// app ended up pasting whatever was on the clipboard *before* our dictation).
    /// 600 ms is comfortably above the practical paste window for every app
    /// we've seen; on a healthy system the user's clipboard manager (Maccy /
    /// Raycast / Paste) won't notice the brief flicker either way.
    private static let clipboardRestoreDelay: TimeInterval = 0.6

    public func insert(text: String) {
        let insertedText = text + " "
        lastInsertedLength = insertedText.count
        let pasteboard = NSPasteboard.general

        // Snapshot the user's clipboard — ALL items, ALL types. The old code
        // only saved `.string`, so any image / RTF / file URL on the clipboard
        // was destroyed by the restore. We deep-copy each item's data per type
        // so the snapshot survives our clearContents().
        let snapshot = snapshotPasteboard(pasteboard)

        // Set our text (trailing space so next dictation/typing continues naturally).
        // The transient marker tells clipboard managers to ignore this write —
        // dictated text shouldn't end up in their history (privacy).
        pasteboard.clearContents()
        pasteboard.setString(insertedText, forType: .string)
        pasteboard.setString("", forType: TextInserter.transientType)

        // Capture the changeCount AFTER our write. If anyone (including the
        // user pressing Cmd+C in the target app, a clipboard manager, etc.)
        // mutates the pasteboard before the restore fires, the count rises
        // above this value and we abort the restore — overwriting the user's
        // post-dictation copy would be worse than leaving our dictated text
        // on the clipboard.
        let changeCountAtOurWrite = pasteboard.changeCount

        // Simulate Cmd+V
        simulatePaste()

        // Restore the user's clipboard after the paste has had time to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + TextInserter.clipboardRestoreDelay) {
            guard TextInserter.shouldRestoreClipboard(
                changeCountAtOurWrite: changeCountAtOurWrite,
                changeCountNow: pasteboard.changeCount
            ) else {
                log("Clipboard restore skipped — user copied something after dictation", tag: "TextInserter")
                return
            }
            TextInserter.restorePasteboard(pasteboard, from: snapshot)
        }
    }

    // MARK: - Clipboard snapshot / restore

    /// Per-type bytes for one NSPasteboardItem. We can't keep a strong reference
    /// to the original NSPasteboardItem and write it back later — once the
    /// pasteboard is cleared, the item's backing data is gone. So we copy out.
    fileprivate struct ItemSnapshot {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    fileprivate func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [ItemSnapshot] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return ItemSnapshot(dataByType: dataByType)
        }
    }

    fileprivate static func restorePasteboard(_ pasteboard: NSPasteboard, from snapshot: [ItemSnapshot]) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let restored: [NSPasteboardItem] = snapshot.map { snap in
            let item = NSPasteboardItem()
            for (type, data) in snap.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    /// Pure decision: was the clipboard untouched since our write?
    /// `pasteboard.changeCount` increments on every write (clearContents +
    /// setData both bump it). Reads — including Cmd+V — do NOT bump it. So if
    /// the count is exactly what we left it at, no one else wrote and our
    /// restore is safe.
    public static func shouldRestoreClipboard(changeCountAtOurWrite: Int, changeCountNow: Int) -> Bool {
        return changeCountAtOurWrite == changeCountNow
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
