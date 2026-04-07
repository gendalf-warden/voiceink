import AppKit
import Foundation

public class HotkeyManager {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var keyCode: UInt16
    private var requiredModifiers: CGEventFlags

    private var isKeyDown = false
    /// Swallow all events for our keyCode until it's physically released
    private var swallowUntilRelease = false
    public var onKeyDown: (() -> Void)?
    public var onKeyUp: (() -> Void)?

    private static let fnFlag = CGEventFlags(rawValue: UInt64(NX_SECONDARYFNMASK))

    /// For Fn-only mode: delay before starting recording so short taps pass through to system
    private static let fnHoldThreshold: TimeInterval = 0.3
    private var fnPressTime: Date?
    private var fnHoldTimer: DispatchWorkItem?
    private var fnRecordingStarted = false

    /// True when hotkey is Fn key alone (no regular key, just the modifier)
    private var isFnOnly: Bool {
        self.keyCode == KeyMap.fnKeyCode && requiredModifiers.rawValue == 0
    }

    // Store a pointer to self for the C callback
    fileprivate static var instance: HotkeyManager?

    public init(keyCode: UInt16, modifiers: [String]) {
        self.keyCode = keyCode
        self.requiredModifiers = Self.parseModifiers(modifiers)
    }

    private var retryTimer: Timer?

    public func start() {
        HotkeyManager.instance = self
        if !tryCreateEventTap() {
            log("No Accessibility permission yet — will retry every 2s", tag: "HotkeyManager")
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                if self.tryCreateEventTap() {
                    timer.invalidate()
                    self.retryTimer = nil
                }
            }
        }
    }

    private func tryCreateEventTap() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: nil
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("Event tap started", tag: "HotkeyManager")
        return true
    }

    public func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        fnHoldTimer?.cancel()
        fnHoldTimer = nil
        eventTap = nil
        runLoopSource = nil
        HotkeyManager.instance = nil
    }

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let eventFlags = event.flags

        // === Fn-only mode ===
        // Short tap (<300ms) → pass through to system (keyboard switch)
        // Long hold (≥300ms) → push-to-talk recording
        if isFnOnly {
            if type == .flagsChanged && eventKeyCode == KeyMap.fnKeyCode {
                let fnPressed = eventFlags.contains(Self.fnFlag)
                if fnPressed && !isKeyDown {
                    // Fn pressed — start timer, don't record yet
                    isKeyDown = true
                    fnPressTime = Date()
                    fnRecordingStarted = false

                    let work = DispatchWorkItem { [weak self] in
                        guard let self = self, self.isKeyDown else { return }
                        self.fnRecordingStarted = true
                        self.onKeyDown?()
                    }
                    fnHoldTimer = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fnHoldThreshold, execute: work)

                    // Pass through — system sees the Fn press (keyboard switch UI may appear)
                    return event

                } else if !fnPressed && isKeyDown {
                    // Fn released
                    isKeyDown = false
                    fnHoldTimer?.cancel()
                    fnHoldTimer = nil

                    if fnRecordingStarted {
                        // Was a long hold — stop recording
                        fnRecordingStarted = false
                        DispatchQueue.main.async { [weak self] in
                            self?.onKeyUp?()
                        }
                    }
                    // Short tap: nothing to do, system handles keyboard switch
                    return event
                }
            }
            return event
        }

        // === Normal modifier+key mode ===
        switch type {
        case .keyDown:
            // If we're swallowing this key until it's released, eat keyDown repeats too
            if swallowUntilRelease && eventKeyCode == keyCode {
                return nil
            }

            // KeyDown requires both correct keyCode AND modifiers
            guard eventKeyCode == keyCode,
                  eventFlags.contains(requiredModifiers) else {
                return event
            }
            if !isKeyDown {
                isKeyDown = true
                swallowUntilRelease = true
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyDown?()
                }
            }
            return nil // Swallow

        case .keyUp:
            // If we're swallowing this key, eat its keyUp and clear the flag
            if swallowUntilRelease && eventKeyCode == keyCode {
                swallowUntilRelease = false
                if isKeyDown {
                    isKeyDown = false
                    DispatchQueue.main.async { [weak self] in
                        self?.onKeyUp?()
                    }
                }
                return nil // Swallow — prevents character from being typed
            }
            return event

        case .flagsChanged:
            // Modifier released while our key was held → treat as key-up
            // Keep swallowUntilRelease=true so the subsequent bare keyDown/keyUp
            // for our keyCode are still eaten
            if isKeyDown && !eventFlags.contains(requiredModifiers) {
                isKeyDown = false
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyUp?()
                }
            }
            return event // Always pass through modifier events

        default:
            return event
        }
    }

    private static func parseModifiers(_ modifiers: [String]) -> CGEventFlags {
        var flags = CGEventFlags()
        for mod in modifiers {
            switch mod.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        return flags
    }

    /// Update hotkey without restarting the event tap
    public func updateHotkey(keyCode: UInt16, modifiers: [String]) {
        self.keyCode = keyCode
        self.requiredModifiers = Self.parseModifiers(modifiers)
        self.isKeyDown = false
        self.swallowUntilRelease = false
        self.fnHoldTimer?.cancel()
        self.fnHoldTimer = nil
        self.fnRecordingStarted = false
        log("Hotkey updated to keyCode=\(keyCode) modifiers=\(modifiers)", tag: "HotkeyManager")
    }

    deinit {
        stop()
    }
}

// C-compatible callback for CGEvent tap
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap disabled events (system may disable tap under load)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = HotkeyManager.instance?.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard let manager = HotkeyManager.instance else {
        return Unmanaged.passUnretained(event)
    }

    if let result = manager.handleEvent(type: type, event: event) {
        return Unmanaged.passUnretained(result)
    }
    return nil // Event was swallowed
}
