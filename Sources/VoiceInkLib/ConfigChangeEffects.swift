import Foundation

/// Pure description of side effects required when `Config` transitions from
/// one value to another. AppDelegate computes one of these on every config
/// change and dispatches the effects on the appropriate threads.
///
/// Lives separately from AppDelegate so transition decisions are testable
/// without spinning up AppKit, audio, or LLM subprocesses. The bug pattern
/// "mode change in menu bar doesn't trigger LLM load" reduces to a
/// `startLLMEagerly` assertion on the right `from → to` pair.
public struct ConfigChangeEffects: Equatable {
    /// Hotkey changed — the event tap needs to rebind.
    public var reloadHotkey: Bool = false
    /// Launch-at-login toggled — LaunchAgent plist needs writing/removing.
    public var updateLaunchAgent: Bool = false
    /// Dictation moved from `.off` to a mode that needs the LLM. Caller must
    /// load the LLM eagerly so the next push-to-talk has it warm.
    /// `false` if an LLM is already running (load would be a no-op).
    public var startLLMEagerly: Bool = false
    /// Dictation moved away from a mode that needed the LLM. The LLM stays
    /// loaded for the current session (file mode may still want it on demand);
    /// caller only needs to drop the "eagerly loaded" flag.
    public var markLLMNotEager: Bool = false

    public init() {}

    /// Compute the effects of moving from `old` to `new`. `llmAlreadyRunning`
    /// is the bundled-llama-server OR Ollama-client liveness at the moment
    /// the diff is taken — it gates redundant `startLLMEagerly`.
    public init(from old: Config, to new: Config, llmAlreadyRunning: Bool) {
        if old.hotkeyKeyCode != new.hotkeyKeyCode
            || old.hotkeyModifiers != new.hotkeyModifiers {
            reloadHotkey = true
        }
        if old.launchAtLogin != new.launchAtLogin {
            updateLaunchAgent = true
        }
        let wasOn = old.dictationMode != .off
        let nowOn = new.dictationMode != .off
        if nowOn && !wasOn && !llmAlreadyRunning {
            startLLMEagerly = true
        }
        if !nowOn && wasOn {
            markLLMNotEager = true
        }
    }
}
