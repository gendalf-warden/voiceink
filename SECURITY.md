# VoiceInk — Security

VoiceInk is a **local-only** macOS dictation app: audio never leaves the machine,
transcription (Whisper) and post-processing (LLM) run as loopback-bound subprocesses,
and the app is distributed as a Developer-ID-signed, notarized DMG with
EdDSA-signed Sparkle auto-updates. This document records the security model and the
results of the source-code audit.

## Security model

- **No cloud / no telemetry.** The only outbound internet connection is the
  first-launch model download (HTTPS, SHA-256-pinned) and the Sparkle update check
  (HTTPS feed, EdDSA-signature-verified). Dictation audio and text stay on-device.
- **Loopback-only local servers.** whisper-server (`:8178`) and llama-server (`:8179`)
  bind to `127.0.0.1` — never `0.0.0.0` — so they are not reachable off-machine.
- **Signed & notarized.** Distributed binaries are signed with Developer ID
  (Team `94QK2GK5GT`), notarized, and stapled. Updates are EdDSA-signed; the public
  key is pinned in `Info.plist` (`SUPublicEDKey`), so a tampered feed or a compromised
  host cannot push an update without the private key (Keychain-only).
- **Minimal entitlements.** Only microphone, `allow-jit`, and
  `allow-unsigned-executable-memory` (the last two required by GGML's runtime Metal
  kernel compilation). `disable-library-validation` is deliberately *not* present.

## Audit — 2026-06-17 (audited 0.5.013, fixes shipped in 0.5.014)

Methodology: OWASP-mapped source review (the web Top-10 adapted to a local macOS
app) across the full attack surface — local IPC/network, subprocess & injection,
file/media & temp handling, clipboard, update & download integrity, cryptography,
secrets, entitlements/signing, and logging. Findings below were verified against the
source; every fix has a regression consideration and the suite stays green
(135 unit tests, 0 build warnings).

**Verdict: no Critical or High findings.** Six hardening items (3 Medium, 3 Low) —
five fixed in 0.5.014, one accepted with rationale.

| ID | OWASP | Severity | Issue | Status |
|----|-------|----------|-------|--------|
| M1 | A10 SSRF | Medium | `ollamaEndpoint` accepted any host → off-machine exfiltration of dictation | ✅ Fixed (0.5.014) |
| M2 | A03 / process control | Medium | Uninstall used broad `pkill -f <name>` substring match | ✅ Fixed (0.5.014) |
| M3 | A01 access control | Medium | Local model servers have no auth (loopback-bound) | ⚖️ Accepted |
| L1 | A08 integrity | Low | Port-based orphan kill was not executable-path-verified | ✅ Fixed (0.5.014) |
| L2 | A08 integrity | Low | Model SHA-256 verification skipped if hash was empty | ✅ Fixed (0.5.014) |
| L3 | A09 logging | Low | Log / config files created `0644` (world-readable) | ✅ Fixed (0.5.014) |

### M1 — Ollama endpoint had no loopback validation (A10 SSRF) — Fixed
`ollamaEndpoint` was read verbatim from `config.json` and POSTed to with the user's
dictated text as the body. A tampered/synced config pointing it at a remote
`https://` host would silently exfiltrate every dictation that falls back to Ollama —
defeating the "no cloud" guarantee. (Plain remote `http://` was already blocked by
App Transport Security, but `https://` passed.)
**Fix:** `Config.sanitizedOllamaEndpoint(_:)` accepts only loopback http(s)
(`localhost`/`127.0.0.1`/`::1`); anything else is rejected on load with a logged
warning and replaced by the safe default. Enforced on the decode path
(`Config.swift`), covered by `ConfigTests.testSanitizedOllamaEndpointRejectsRemote`.

### M2 — Uninstall killed processes by broad substring match (A03) — Fixed
`performUninstall()` ran `pkill -f whisper-server` / `llama-server`, matching the
substring against every user process's full command line — capable of killing
unrelated processes. **Fix:** uninstall now calls
`ProcessHygiene.killOrphans(executablePath:port:)` with the resolved bundled paths,
which matches the exact executable path plus a path-verified port cross-check
(`SettingsWindowController.swift`).

### M3 — Local model servers have no authentication (A01) — Accepted
whisper-server and llama-server expose unauthenticated HTTP on loopback, so any
local peer process running as the same user can drive them while VoiceInk runs.
**Accepted** because: (a) they are bound to `127.0.0.1` (no network exposure),
(b) no transcript history is exposed, (c) exploitation requires pre-existing local
code execution as the same user, and (d) whisper-server (upstream whisper.cpp) has
no auth option. The loopback bind is the control and must never change to `0.0.0.0`.
*Optional future hardening:* pass a random per-launch `--api-key` to llama-server.

### L1 — Port-based orphan kill was not path-verified (A08) — Fixed
`ProcessHygiene.killByPort` SIGKILL'd whatever held `:8178`/`:8179` at launch without
confirming it was a VoiceInk binary, so a port collision could kill an unrelated
process. **Fix:** the PID's executable is now resolved via `proc_pidpath` and must
match the bundled server path (symlink-resolved) before it is killed; otherwise it is
logged and skipped (`ProcessHygiene.swift`). *(PID parsing was already safe — a PID is
taken from the kernel-emitted column, never parsed out of attacker-influenced text.)*

### L2 — Model SHA-256 verification was conditional (A08) — Fixed
Verification ran only `if !asset.sha256.isEmpty`; an asset added with an empty hash
would have installed unverified. **Fix:** the check now fails closed — a missing
pinned hash throws before the model is used (`ModelManager.swift`). Downloads remain
HTTPS from a fixed repository tag, verified before unzip/use.

### L3 — Log / config file permissions (A09) — Fixed
`voiceink.log` and `config.json` were created at default `0644`. The log can contain
dictation text when the `logTranscriptions` opt-in is enabled. **Fix:** both are now
created `0600`, and a pre-existing log from an older build is tightened on launch
(`Logger.swift`, `Config.swift`). By default the log records only usage metadata and
redacted shapes (`[N chars, M words]`) — never transcription content unless opted in.

### Verified safe (checked, not issues)

- **Auto-update integrity:** HTTPS feed + EdDSA signature pinning; a compromised
  GitHub Pages host cannot push a malicious update without the Keychain-only private key.
- **No shell execution:** all subprocess spawns use `Process` argument arrays with
  absolute paths — no `/bin/sh -c`, `system`, or `osascript`.
- **No keylogging:** the Accessibility `CGEventTap` reads only keyCode/flags for the
  hotkey; it never reads typed character payloads, and non-hotkey events pass through.
- **Temp audio:** recordings use UUID names inside the per-user `0700` container
  (not `/tmp`) and are deleted on every path, including errors.
- **Clipboard:** the paste path snapshots all pasteboard types, marks its write
  transient, and skips restore if the user copied during the window.
- **No URL handler / deep links;** no extra listening sockets, XPC, or IPC.
- **Media decode:** AVFoundation (Apple) decodes containers; bundled whisper.cpp only
  ever receives clean PCM.

### Components

Sparkle 2.x · OpenSSL 3.x (loopback-only, no exposed TLS termination) ·
ggml 0.9.11 / whisper.cpp / llama.cpp. No known remotely-exploitable CVE applies to
the local-only usage; the known GGML Metal deadlock is a functional (not security)
issue tracked in `PROJECT.md`.

## Reporting a vulnerability

VoiceInk is maintained privately. Report security issues to the repository owner
(`gendalf-warden/voiceink`) rather than opening a public issue. Please include
affected version (see the menu-bar "VoiceInk vX.Y.Z"), reproduction, and impact.
