# Changelog

All notable changes to VoiceInk are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- **Replacements dictionary** (P5.4): user-defined word replacements applied after
  Whisper, before LLM. Native macOS table editor with live search field, click-to-edit
  cells, ±  buttons. Menu: Replacements… (Cmd+R)
- **LLM lazy lifecycle**: when dictation punctuation is OFF but file punctuation is
  ON, LLM is loaded only during file transcription and unloaded after — saves ~2 GB
  idle RAM
- **Settings: «Умная пунктуация» grouped block** with RAM hint showing actual machine
  memory (e.g. "Требует 16+ ГБ RAM (у вас: 36 ГБ)")
- **UIPreview executable target** for fast UI iteration: `./scripts/preview-ui.sh`
  compiles in ~1.5s and launches a single window without the .app bundle. Isolated
  config in /tmp via VOICEINK_CONFIG_DIR env var
- **Whisper.cpp hallucination fix**: hardcoded `/inference` path issue (already in
  v1.8.4 upstream — backlog item to update)

### Changed
- Dev build version label is now `{VERSION}+dev` instead of just `dev` (visible
  base version + dev marker)
- Build scripts use `--scratch-path /tmp/voiceink-build-scratch` to avoid iCloud
  Drive ModuleCache rename races
- LLM startup logic refactored: `startLLMSync()` / `ensureLLMReady()` /
  `releaseLazyLLM()` helpers in AppDelegate; FileTranscriptionManager uses
  callbacks for LLM lifecycle (onLLMNeeded/onLLMRelease)

### Fixed
- LLM was not started when only file transcription needed it (previously checked
  only dictation flag)

## [0.2b] - 2026-04-17

### Added
- **Chunked file transcription** — splits WAV into 30s chunks at silence boundaries, streams results
- **Parallel ASR/LLM pipeline** — concurrency=2, 2.1× speedup (9× → 18.7× RTF on 45-min file)
- **Streaming result window** — progress bar, live stats, elapsed + ETA, realtime factor, words/min
- **Export transcription** as TXT / SRT / MD (save dialog with format popup)
- **Timestamp toggle** in result window
- **Whisper hallucination filter** — strips "Продолжение следует...", lone "you", subtitle credits
- **Standalone hallucination removal** — entire chunks that are just hallucinations dropped
- **Language detection + script verification**: auto-detect from first chunk, re-transcribe mismatched chunks with forced language, drop if still mismatched
- **CJK character stripping** — defense against Chinese/Japanese/Korean hallucinations on unclear audio
- **LLM translation detection** — if LLM changed script while raw was correct, use raw (qwen2.5:3b sometimes ignores "do not translate" rule)
- **Trailing silence trim** in AudioRecorder — prevents Whisper hallucinations at recording end
- **Min recording length** (0.5s) — skips accidental Fn taps
- **Undo Dictation** menu item (Cmd+Z) — selects and deletes last inserted text
- **Split smart-punctuation toggle**: separate settings for dictation (default on) and file transcription (default off)
- 33 new unit tests: AudioConverter chunking, Transcriber (hallucinations, scriptMatches, stripForeignChars, toISOCode)

### Changed
- **LLM prompt** hardened against hallucination on short phrases ("save memory" → essay)
- **3× length guard** for LLM output — if result is 3× longer than input, use raw text
- Settings window widened 420 → 500px for longer Russian labels
- Settings label renamed: "Продвинутая пунктуация" → "Умная пунктуация при диктовке" + new "... при транскрипции файлов"
- `build-app.sh` auto-strips `com.apple.provenance` xattr to prevent macOS launch blocks

### Fixed
- Chinese/Japanese/Korean hallucinations in Russian audio
- English hallucinations on noisy Russian chunks ("To be two bases were identical")
- LLM translating Russian to English despite "do not translate" in prompt
- Whisper language API: ISO code normalization (whisper returns "russian", -l expects "ru")

## [0.1b] - 2026-04-07

### Added
- Push-to-talk voice dictation with Fn hotkey (or any modifier+key)
- whisper-server ASR with large-v3-turbo model (Metal + CoreML)
- LLM punctuation via bundled llama-server + Ollama fallback
- File transcription (mp3, wav, m4a, mp4, mov) with LLM post-processing
- Settings window with hotkey recorder, punctuation toggle
- Menu bar with animated state icons and version number
- Splash window with progress bar at startup
- DMG installer with drag-to-Applications
- First-run wizard for Microphone + Accessibility permissions
- Auto-retry CGEventTap (no restart needed after granting Accessibility)
- Punctuation toggle for low-RAM machines (disabled by default on <=8 GB)
- Dev/release build separation with VERSION file
