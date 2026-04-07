# Changelog

All notable changes to VoiceInk are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/).

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
