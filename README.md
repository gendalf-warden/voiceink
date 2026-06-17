# VoiceInk

Native macOS menu-bar voice dictation. Local Whisper transcription + local LLM
punctuation/editing. No cloud, no subscription — everything runs on your Mac inside a
self-contained `.app`.

- **Download / install:** https://gendalf-warden.github.io/voiceink/
  ([install guide](https://gendalf-warden.github.io/voiceink/install.html))
- **Requirements:** macOS 13+, Apple Silicon.
- Current version: see [`VERSION`](VERSION).

## What it does

- Hold **Fn** anywhere, dictate, release — the text is pasted at your cursor.
- Whisper large-v3-turbo for transcription (runs locally, Metal-accelerated).
- Qwen 2.5 for punctuation & light editing (also local).
- Transcribe audio/video files from the menu bar.
- Custom replacements dictionary for tricky names.

## Build

```bash
swift build              # debug (dev mode; uses system paths, needs Ollama)
swift run                # run dev mode
./build-app.sh           # dev .app bundle (version "dev", no DMG)
./build-app.sh release   # release .app + signed/notarized DMG (version from VERSION)
swift test               # unit tests
```

See [`CLAUDE.md`](CLAUDE.md) for the full build/bundling details (dylib bundling,
GGML backends, code signing, Sparkle auto-update).

## Security

VoiceInk is local-only: audio and text never leave the machine; the model servers are
loopback-bound; the app is Developer-ID-signed + notarized and updates are
EdDSA-signed. The security model and the latest source-code audit (OWASP-mapped) are
in **[`SECURITY.md`](SECURITY.md)** — which also documents how to report a vulnerability.

## Documentation

| Doc | Purpose |
|-----|---------|
| [`SECURITY.md`](SECURITY.md) | Security model + audit findings + vulnerability reporting |
| [`CLAUDE.md`](CLAUDE.md) | Architecture, build, conventions, solved bugs |
| [`PROJECT.md`](PROJECT.md) | Full status, decisions, backlog |
| [`CHANGELOG.md`](CHANGELOG.md) | Per-version change history |
| [`TESTS.md`](TESTS.md) | Regression test checklist |
| `architecture.html` | Interactive architecture diagram |
