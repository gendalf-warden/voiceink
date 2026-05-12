import XCTest
@testable import VoiceInkLib

/// Transition tests for the config diff that drives AppDelegate.applyConfig.
/// Each case below corresponds to a user action that has historically caused
/// (or could cause) a silent lifecycle bug. The bug pattern fixed in 0.4b
/// "switching dictation mode in menu bar doesn't load the LLM" is captured
/// by `testDictationOffToTranslateRequestsLLMStart` — that test would have
/// failed before the fix.
final class ConfigChangeEffectsTests: XCTestCase {

    // MARK: - Helpers

    private func baseConfig() -> Config {
        Config(
            whisperCliPath: "", whisperServerPath: "", whisperModelPath: "",
            language: "auto", hotkeyKeyCode: 63, hotkeyModifiers: [],
            llamaServerPath: "", llamaModelPath: "",
            ollamaEnabled: true, ollamaModel: "", ollamaEndpoint: "",
            launchAtLogin: false, logTranscriptions: false,
            dictationMode: .off, fileMode: .off,
            translateTarget: "en"
        )
    }

    // MARK: - No-op transition

    func testIdenticalConfigsProduceNoEffects() {
        let cfg = baseConfig()
        let effects = ConfigChangeEffects(from: cfg, to: cfg, llmAlreadyRunning: false)
        XCTAssertEqual(effects, ConfigChangeEffects())
    }

    // MARK: - Hotkey

    func testHotkeyKeyCodeChangeReloadsHotkey() {
        var old = baseConfig(); var new = baseConfig()
        new.hotkeyKeyCode = 18
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: false)
        XCTAssertTrue(effects.reloadHotkey)
        XCTAssertFalse(effects.updateLaunchAgent)
    }

    func testHotkeyModifierChangeReloadsHotkey() {
        var old = baseConfig(); var new = baseConfig()
        new.hotkeyModifiers = ["cmd", "shift"]
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: false)
        XCTAssertTrue(effects.reloadHotkey)
    }

    // MARK: - Launch-at-login

    func testLaunchAtLoginToggleTriggersAgentUpdate() {
        var old = baseConfig(); var new = baseConfig()
        new.launchAtLogin = true
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: false)
        XCTAssertTrue(effects.updateLaunchAgent)
    }

    // MARK: - Dictation mode → LLM lifecycle

    /// The exact bug that shipped in 0.4b-dev: switching dictation from .off to
    /// .translate in the menu bar didn't load the LLM. With ConfigChangeEffects
    /// in place, this is now a pure-function assertion.
    func testDictationOffToTranslateRequestsLLMStart() {
        var old = baseConfig(); var new = baseConfig()
        new.dictationMode = .translate
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: false)
        XCTAssertTrue(effects.startLLMEagerly,
                      ".off → .translate must request eager LLM load")
        XCTAssertFalse(effects.stopLLM)
    }

    func testDictationOffToSmartRequestsLLMStart() {
        var old = baseConfig(); var new = baseConfig()
        new.dictationMode = .smart
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: false)
        XCTAssertTrue(effects.startLLMEagerly)
    }

    func testDictationOffToOffIsNoOp() {
        let cfg = baseConfig()
        let effects = ConfigChangeEffects(from: cfg, to: cfg, llmAlreadyRunning: false)
        XCTAssertFalse(effects.startLLMEagerly)
        XCTAssertFalse(effects.stopLLM)
    }

    func testDictationSmartToOffStopsLLM() {
        var old = baseConfig(); old.dictationMode = .smart
        let new = baseConfig() // .off
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: true)
        XCTAssertTrue(effects.stopLLM, ".smart → .off must unload LLM to free RAM")
        XCTAssertFalse(effects.startLLMEagerly,
                       "going to .off should not request a new LLM start")
    }

    func testDictationTranslateToOffStopsLLM() {
        var old = baseConfig(); old.dictationMode = .translate
        let new = baseConfig() // .off
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: true)
        XCTAssertTrue(effects.stopLLM)
    }

    func testDictationSmartToTranslateKeepsLLMRunning() {
        // Both modes need the LLM; we don't restart it just because the prompt changes.
        var old = baseConfig(); old.dictationMode = .smart
        var new = baseConfig(); new.dictationMode = .translate
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: true)
        XCTAssertFalse(effects.startLLMEagerly)
        XCTAssertFalse(effects.stopLLM,
                       "mode-to-mode swap should not flap the eager flag")
    }

    func testDictationOffToTranslateWithLLMAlreadyRunningSkipsRestart() {
        // E.g. file mode lazy-loaded the LLM and it happens to still be up
        // when the user toggles dictation on. Don't try to start it again.
        var old = baseConfig(); var new = baseConfig()
        new.dictationMode = .translate
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: true)
        XCTAssertFalse(effects.startLLMEagerly,
                       "should not restart an LLM that's already running")
    }

    // MARK: - File mode does NOT trigger eager start

    func testFileModeChangeDoesNotTriggerEagerLLMStart() {
        // File mode uses lazy load — applyConfig should ignore it for eager lifecycle.
        var old = baseConfig(); var new = baseConfig()
        new.fileMode = .smart
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: false)
        XCTAssertFalse(effects.startLLMEagerly)
        XCTAssertFalse(effects.stopLLM)
    }

    func testFileModeChangeToTranslateDoesNotTriggerEagerLLMStart() {
        var old = baseConfig(); var new = baseConfig()
        new.fileMode = .translate
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: false)
        XCTAssertFalse(effects.startLLMEagerly)
    }

    // MARK: - Combined transitions

    func testHotkeyAndDictationModeChangeTogetherProduceBoth() {
        var old = baseConfig(); var new = baseConfig()
        new.hotkeyKeyCode = 18
        new.dictationMode = .translate
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: false)
        XCTAssertTrue(effects.reloadHotkey)
        XCTAssertTrue(effects.startLLMEagerly)
    }

    func testTranslateTargetChangeAloneIsNoOp() {
        // Changing translate target while modes don't change — no LLM restart.
        var old = baseConfig(); old.dictationMode = .translate; old.translateTarget = "en"
        var new = baseConfig(); new.dictationMode = .translate; new.translateTarget = "ru"
        let effects = ConfigChangeEffects(from: old, to: new, llmAlreadyRunning: true)
        XCTAssertEqual(effects, ConfigChangeEffects(),
                       "translate target change is a runtime prompt change, not a lifecycle event")
    }
}
