# Changelog

All notable changes to VoiceInk are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

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
