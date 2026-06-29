# Changelog

All notable changes to VoiceInk are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Fixed — low-RAM file transcription hang (Katya's M2 8 GB)
On ≤8 GB machines, a long file transcription (Katya: 92-min / 184-chunk meeting)
could hang both servers on the first attempt: the LLM `warmup` timed out, then the
whisper-server watchdog fired (`SIGTERM ignored → SIGKILL`), and the app had to be
force-relaunched before a retry succeeded.

**Cause:** the low-RAM "sequential ASR→LLM phases" mitigation was only sequential at
the *request* level. `runPipeline` eager-loaded the llama-server at the *start* of the
file transcription, so its ~2.5 GB working set sat resident in RAM throughout the
entire whisper ASR pass — exactly the working-set overlap the mitigation was meant to
prevent → swap thrash → timeouts.

**Fix:** in low-RAM mode the LLM is now loaded *between* phases — Phase 1 runs all ASR
with whisper as the only resident model, then the llama-server is brought up only for
Phase 2 post-processing. `runLLM` checks server liveness live (instead of a captured
ready-flag) so it works whether the LLM was loaded eagerly (normal path) or lazily
mid-pipeline (low-RAM path). Non-low-RAM behaviour is unchanged. `FileTranscriptionManager.swift` only.

## [0.5.014] - 2026-06-17

### Security
OWASP-mapped source audit (see new [`SECURITY.md`](SECURITY.md)) — no Critical/High;
five hardening fixes applied:
- **M1 (SSRF):** `ollamaEndpoint` is now validated as loopback-only
  (`Config.sanitizedOllamaEndpoint`) — a tampered config can no longer point the
  Ollama fallback at a remote host and exfiltrate dictated text. +2 regression tests.
- **M2:** uninstall kills the bundled servers by exact executable path via
  `ProcessHygiene.killOrphans` instead of a broad `pkill -f <name>` substring match.
- **L1:** `ProcessHygiene` port-based kill now verifies the PID's executable
  (`proc_pidpath`) matches the bundled server before SIGKILL — no more killing an
  unrelated process that merely holds the port.
- **L2:** model SHA-256 verification fails closed when no pinned hash is configured.
- **L3:** `voiceink.log` and `config.json` are created `0600` (were `0644`); a
  pre-existing log is tightened on launch.

Added `README.md` (was missing) with a Security section linking `SECURITY.md`.

## [0.5.013] - 2026-06-06

### Added — field diagnostics
Triaging Anna's report meant *inferring* almost everything (version from bundle
paths, "Thank you." from a `[10 chars]` count, silence from a duration/length
ratio). These logs make the next report readable instead of guessable. Privacy
principle: dropped/filtered text is rejected junk (never inserted), so it's
logged verbatim; real dictated text stays behind the `logTranscriptions` opt-in.
- **Startup diagnostic banner**: one block per launch with app version+build,
  chip model (→ which ggml CPU backend applies), macOS version, RAM, microphone
  & accessibility permission states, hotkey, modes, and — crucially for the
  "no backends" class — the list of ggml backend `.so` bundled next to
  llama-server (`NONE ⚠️` if missing).
- **Recording stats**: every stop logs duration + peak amplitude, so a
  silence-driven hallucination is obvious (`4.8s, peak 0.004`). Skip reasons
  (too-short / silent) now include the numbers.
- **Filter/drop visibility**: `Transcriber` logs what the hallucination filter
  removed (`dropped entire output: "Thank you."`); the pipeline logs when a
  transcription is empty after filtering (the phantom-text path) — confirms the
  0.5.011 fixes are firing in the field.
- **Hotkey trigger classification**: logs `Fn held ≥300ms → push-to-talk` vs
  `Fn+key combo — push-to-talk cancelled`, so accidental triggers are visible.
- **Redacted transcription signature**: `[N chars, M words]` instead of bare
  `[N chars]` when full-text logging is off.

### Fixed — build warnings (0-warnings gate)
- Cleared all 6 pre-existing `#SendableClosureCaptures` warnings so `develop`
  passes CLAUDE.md's "swift build — 0 warnings" gate on a *clean* build
  (`rm -rf .build && swift build`). `AppDelegate` error-tail now uses
  `Task.sleep` + `MainActor.run` instead of a `@Sendable`
  `DispatchQueue.asyncAfter` closure; `AudioConverter`'s `requestMediaDataWhenReady`
  callback (which runs serially on a dedicated queue) rebinds its AVFoundation
  objects `nonisolated(unsafe)`. No behavior change. (Note: only 2 showed in
  incremental builds — the other 4 in `AudioConverter` only surface on a clean
  build because that file isn't otherwise recompiled.)

## [0.5.012] - 2026-06-06

### Fixed
- **Bundled llama-server "no backends are loaded" on clean machines** (the
  known issue flagged in 0.5.011): on a user's Mac the bundled llama-server
  crashed on every launch (exit 1, `no backends are loaded`), so LLM
  post-processing silently fell back to Ollama (absent) and every dictation
  used raw Whisper with no cleanup. Root cause: newer ggml (0.9.11) discovers
  GPU/CPU/BLAS backend plugins (`.so`) by searching the directory that contains
  the executable **plus a compile-time-hardcoded homebrew Cellar path**, and
  `GGML_BACKEND_PATH` dlopen's a single explicit *file*, not a directory. The
  app shipped the `.so` in `Resources/lib-llama/` and set
  `GGML_BACKEND_PATH=lib-llama/` (a directory) — so on a machine without
  homebrew, nothing loaded. It only worked on dev machines because the
  hardcoded `/opt/homebrew/Cellar/ggml/.../libexec` happened to exist.
  Fix: `build-app.sh` now copies the backend `.so` files into `Resources/`
  next to `llama-server` (their dylib deps stay in `lib-llama/`, resolved via
  an `@loader_path/lib-llama` rpath), and `LlamaClient` no longer sets the
  bogus directory-valued `GGML_BACKEND_PATH`. ggml's relocatable
  executable-dir search then finds the backends on any machine. whisper-server
  (older whisper.cpp, no `.so`-plugin loader) is unaffected.

## [0.5.011] - 2026-06-06

Phantom text reported by a user (Anna): while editing documents — not dictating
— phrases like "Thank you." and "click click click click" inserted themselves
mid-word (e.g. "Matosinhos" became "M Thank you. atosinhos"). Log analysis
showed the root-cause chain and three independent fixes.

### Fixed
- **Accidental Fn-hold triggering recording during normal editing**: with the
  default `Fn`-only hotkey, holding `Fn` ≥300ms as part of a combo (`Fn`+arrows
  for navigation, `Fn`+Delete for forward-delete, `Fn`+F-keys) started a
  push-to-talk recording. `HotkeyManager` now cancels the pending recording the
  moment another key is pressed while `Fn` is held — a `Fn`+<key> combo is no
  longer mistaken for push-to-talk.
- **Whisper hallucinating on silence/noise and pasting it into the document**:
  multi-second recordings of silence produced phantom phrases (5–6s of audio →
  a bare "Thank you."). `AudioRecorder.isSilent(url:)` now detects recordings
  whose peak amplitude never crosses the speech floor and `AppDelegate` drops
  them before transcription.
- **`removeHallucinations()` missing common artifacts**: it caught "thank you
  for watching" but not a standalone "Thank you", nor repetition loops
  ("click click click click" from keyboard noise), nor RU "Спасибо за просмотр".
  Added standalone-only phrase removal (never stripped mid-sentence so
  "…thank you for this." survives) and a repeated-word-loop detector.

### Known issues
- **Bundled llama-server crashes on startup on some machines** (`no backends
  are loaded`, exit 1) → raw Whisper text with no cleanup. **Fixed in 0.5.012.**

## [0.5.010] - 2026-06-02

### Fixed
- **Unfriendly Gatekeeper first-launch dialog (continued from 0.5.009)**: despite
  passing `codesign --verify --deep --strict` cleanly and being fully notarized
  + stapled, the app still showed "Apple could not verify VoiceInk is free of
  malware. Done / Move to Trash" on macOS 15 instead of the friendly "App
  downloaded from Internet — Open?". Hypothesis: macOS 15's Gatekeeper folds
  the `com.apple.security.cs.disable-library-validation` entitlement into its
  first-launch risk assessment. We removed that entitlement — all bundled
  dylibs / .so / Sparkle.framework internals are re-signed by `build-app.sh`
  with our Developer ID (Team 94QK2GK5GT), so library validation succeeds
  natively without the disable flag. The entitlement was a relic from when we
  shipped homebrew-signed libs without re-signing them.

## [0.5.009] - 2026-06-01

### Fixed
- **Gatekeeper "Apple could not verify" dialog on first launch**: brand-new
  installs from the DMG showed the restrictive macOS 15 dialog ("Done / Move
  to Trash" → System Settings → Open Anyway) instead of the friendly
  "downloaded from Internet — Open?" prompt that every well-notarized macOS
  app gets. Despite `xcrun stapler validate` passing and `spctl` accepting,
  `codesign --verify --deep --strict` flagged a "Disallowed xattr
  com.apple.FinderInfo" on `Sparkle.framework/.../Updater.app`. The xattr was
  inherited from the SPM artefact in iCloud Drive (which decorates every file
  it touches with `com.apple.FinderInfo` and friends) and survived the
  `xattr -cr` sweep because some system xattrs ignore `-c`. `build-app.sh` now
  copies the framework with `ditto --noextattr --noacl` (skips xattrs at the
  source) and follows up with a per-file `xattr -c` via `find -exec`. Result:
  `codesign --verify --strict` is clean, and Gatekeeper shows the friendly
  first-launch dialog.

## [0.5.008] - 2026-05-31

Two production bugs reported on an 8 GB Mac under heavy daily dictation use:
whisper-server orphans piling up between sessions, and the post-dictation
clipboard restore racing with the paste so that the previous clipboard
contents were pasted instead of the transcription. The two compound — orphans
caused memory pressure → the paste race tripped more often.

### Fixed
- **Orphaned whisper-server / llama-server processes** (`Sources/VoiceInkLib/ProcessHygiene.swift`,
  hooked from `AppDelegate.applicationDidFinishLaunching` and
  `startLLMSync`). Cleanup previously lived only in `shutdown()`, wired to the
  Quit menu item. Every other exit path — SIGTERM/SIGINT at logout, the
  Settings → Uninstall flow, the model-download cancel button, crashes, jetsam
  OOM-kills — reparented child processes to launchd and left them holding
  ~600 MB each. Worse: an orphan still bound to `:8178` continued returning
  HTTP 200 to `waitForServer()`, so the freshly spawned whisper-server failed
  to bind silently and the app drove the stale orphan. Two-part fix:
  - **`ProcessHygiene.killOrphans()`** runs at app launch BEFORE
    `Transcriber.startServer()` / `LlamaClient.startServer()`. It matches by
    bundled executable path (so a homebrew or system `whisper-server` is
    untouched) and cross-checks `lsof :8178` / `:8179` to catch processes the
    path match misses. SIGKILL — orphans are already untracked.
  - **`AppDelegate.applicationWillTerminate(_:)`** now calls `shutdown()`,
    closing the SIGTERM/SIGINT and Settings-uninstall paths. `shutdown()` is
    idempotent (guarded by `didShutdown`) so the Quit menu + this hook
    can't double-stop.
- **Clipboard race in `TextInserter.insert`** (`Sources/VoiceInkLib/TextInserter.swift`).
  Previously: save `.string`, write dictation, fire Cmd+V, restore after
  **150 ms hard-coded delay**. Under memory pressure or in heavy apps the
  target hadn't consumed the paste yet, so the restore won the race and the
  app pasted the old clipboard. Also, only `.string` was preserved —
  images / RTF / file URLs on the clipboard were destroyed. Three fixes:
  - Snapshot ALL pasteboard items and ALL types (not just `.string`); restore
    them all on the round-trip.
  - Delay raised 150 ms → **600 ms**, comfortably above the practical paste
    window for every app we've seen.
  - Skip the restore entirely if `NSPasteboard.changeCount` rose between our
    write and the restore deadline (the user pressed Cmd+C in the target app
    after dictation; clobbering their fresh copy would be worse than leaving
    our dictated text on the clipboard).

### Internal
- `ProcessHygiene.parseOrphanPIDs` is a pure function with 9 unit tests
  covering exact path matches, multiple orphans, own-PID safety,
  homebrew/system binaries with the same filename, prefix-substring
  rejection, leading whitespace in `ps` output, and malformed lines.
- `TextInserter.shouldRestoreClipboard` is a pure function with 4 unit tests
  covering the changeCount comparator.

## [0.5.007] - 2026-05-23

### Changed
- **Menu-bar icon position persistence**: `NSStatusItem.autosaveName = "VoiceInk"`.
  Without this, macOS picks a default slot at every launch — often behind the
  camera notch on MacBook Air/Pro 14" — and the user has to Cmd+drag the icon
  each time. With autosaveName set, the OS remembers the user's chosen
  position across launches. Doesn't avoid the initial under-notch position on
  first install (Apple offers no API for that), but at least the user only has
  to move it once.

### Internal
- First release exercising the canonical post-migration update flow: 0.5.006
  clients fetch this version directly from GH Pages via the baked-in
  `SUFeedURL`, no GitHub Releases bridging involved.

## [0.5.006] - 2026-05-23

Critical fixes for Sparkle install. 0.5.005 could find updates but not install
them — Autoupdate failed with `Operation not permitted` when creating its
install cache directory. Root cause: `build-app.sh` was re-signing
Sparkle.framework's internal XPC services + Updater.app + Autoupdate with the
host app's entitlements (audio-input, JIT, etc.). Those entitlements require an
`NSMicrophoneUsageDescription` in the binary's Info.plist, which Sparkle's
internals don't have, so macOS neutered the processes and Autoupdate couldn't
write to its own cache.

### Fixed
- **Sparkle install permission failures**: `build-app.sh` now signs
  Sparkle.framework internals with a new `sign_no_ent` helper that uses
  `--options runtime` but no `--entitlements` flag. Host app and our own
  bundled binaries (whisper-server, llama-server, voiceink) still sign with
  the project's `entitlements.plist`.
- **`codesign --deep --strict` resource-fork errors on Installer.xpc**:
  `xattr -cr` now runs against `Sparkle.framework` after copy to strip
  `com.apple.FinderInfo` xattrs that `ditto` preserved from the SPM
  artefact's iCloud-Drive location.
- **Race condition on GH Pages propagation during dual-publish**: legacy
  0.5.003 clients hitting the old GitHub Releases appcast URL could be
  directed to a DMG that GH Pages hadn't propagated yet (404). `release.sh`
  now publishes to `gh-pages` FIRST, waits for the Pages build to finish
  (polling the GH API + verifying the DMG is reachable), and only THEN
  uploads the appcast to GitHub Releases as the bridging mirror.

## [0.5.005] - 2026-05-23

### Fixed
- **Sparkle update dialog opening behind the active app**: for an
  accessory (menu-bar) app, clicking «Check for Updates…» didn't bring the
  process to the front, so the modal Sparkle alert appeared behind Safari /
  Chrome / whatever else was focused — the user thought the menu item did
  nothing. `UpdateController` now implements `SPUStandardUserDriverDelegate`
  and forces `NSApp.activate(ignoringOtherApps:)` from
  `standardUserDriverWillShowModalAlert()`, which Sparkle calls right before
  presenting any modal. Belt-and-braces: we also activate immediately when
  the user clicks the menu item, before the network round-trip starts.

## [0.5.004] - 2026-05-23

Distribution migration: DMG and Sparkle appcast move from GitHub Releases to
GitHub Pages (`https://gendalf-warden.github.io/voiceink/`). The user-facing
download URL is now a clean static page that lists only the DMG — no
GitHub-generated source-code archives. Source remains in the same repository
but is not surfaced in the install flow.

**Bridging release**: 0.5.004 is published to BOTH the old GitHub Releases
URL (so already-installed 0.5.003 clients can find it via their baked-in
`SUFeedURL`) and the new GH Pages URL. From 0.5.004 onwards the app's
Info.plist references the new URL; subsequent releases publish only to
GH Pages.

### Changed
- `SUFeedURL` in Info.plist:
  `https://github.com/gendalf-warden/voiceink/releases/latest/download/appcast.xml`
  → `https://gendalf-warden.github.io/voiceink/appcast.xml`
- `scripts/release.sh` now dual-publishes: pushes DMG + appcast.xml + latest.json
  + a regenerated index.html to the `gh-pages` branch, AND uploads the same DMG
  to a GitHub Release tag for 0.5.003 clients to discover this update.
- Old GitHub Release tags (`v0.1b` … `v0.5.003`) will be deleted after the
  migration completes.

## [0.5.003] - 2026-05-22

Hotfix for 0.5.002 — the app crashed on launch with `Library not loaded:
@rpath/Sparkle.framework/Versions/B/Sparkle`. The main `voiceink` binary lacked
an rpath pointing at `Contents/Frameworks/`, so dyld searched only
`Contents/MacOS/` (and standard system Swift paths) and didn't find
Sparkle.framework. 0.5.002 was never publicly usable.

### Fixed
- `build-app.sh` now runs `install_name_tool -add_rpath
  @executable_path/../Frameworks` on the main binary right after copying it —
  before codesigning, since modifying a signed binary invalidates the signature.

## [0.5.002] - 2026-05-22

Adds the first auto-updater. From this release on, future updates can be
installed in-app via the «Check for Updates…» menu item — no more manual DMG
drag-to-Applications. Pre-0.5.002 users (0.5.001 and earlier) still need to
install this release manually one time to get the Sparkle infrastructure;
after that, all subsequent updates flow through Sparkle.

### Added
- **Auto-updater via Sparkle 2.x**: «Check for Updates…» menu item in the menu
  bar fetches `appcast.xml` from GitHub Releases, compares versions, downloads
  the new DMG, verifies its ed25519 signature against the `SUPublicEDKey`
  baked into Info.plist, swaps the .app in `/Applications`, and relaunches.
  Models in `~/Library/Application Support/VoiceInk/models/` (~3.5 GB) are
  **not** redownloaded — Sparkle only replaces the .app bundle, and ModelManager
  on next launch checks model presence/version independently. So a code-only
  update is the ~13 MB DMG, nothing more. Models are only re-fetched when
  the `modelsTag` constant in `ModelManager.swift` is bumped (next time we
  switch whisper or qwen models). Automatic checks are disabled
  (`SUEnableAutomaticChecks = false`) — user-initiated only.
- **Sparkle release tooling**: `scripts/sparkle-generate-keys.sh` (one-time
  ed25519 key generation, stored in Keychain), `scripts/sparkle-sign-dmg.sh`
  (per-release signing). `scripts/release.sh` extended to generate and publish
  `appcast.xml` alongside the existing `latest.json` and DMG.

### Internal
- DMG size went from 11 MB → 13 MB due to bundled Sparkle.framework
  (~2 MB including XPCServices, Updater.app, Autoupdate helper).

## [0.5.001] - 2026-05-22

First release under the new versioning scheme (`MAJOR.MINOR.PATCH`, replaces the
`0.Xb` beta notation). This release accumulates fixes for long-file transcription
stability and the file-transcription window UX.

### Added
- **Whisper watchdog** (Transcriber): on URL timeout / connection lost /
  cannot-connect-to-host, kill and restart `whisper-server`, then retry the
  request once. Breaker after 10 restarts per session. Applied to all calls
  (dictation + files), all machines. Root cause: a cumulative deadlock in
  `__ggml_metal_rsets_init` inside `libggml-metal.0.9.6.dylib` that triggers
  after ~150-180 `/inference` requests on a hot process, on both 8 GB and 36 GB
  Macs (so the bug is not RAM-related). See CLAUDE.md → Решённые баги.
  Hardening included: (a) **coalescing window** (5 s) so racing watchdog calls
  under concurrency=2 don't double-restart and kill each other's fresh servers;
  (b) **wait-for-exit + SIGKILL fallback** in `stopServer()` — a Metal-deadlocked
  process ignores SIGTERM (its Metal thread is in a usleep retry-loop and never
  returns to the signal handler), so without an explicit `process.isRunning` poll
  and a SIGKILL after 3 s, restart() leaks 2-3 zombie processes per restart;
  (c) per-file `resetWatchdog()` so the restart budget refreshes for each new
  transcription.
- **Proactive restart**: whisper-server is now cycled every 100 `/inference`
  calls, well below the ~150-call deadlock threshold. Cost: ~10 s per restart,
  amortized 2-3 restarts per long file. Benefit: users normally never see a
  watchdog timeout in the log. With concurrency=2 the second in-flight request
  may be killed mid-flight by the proactive cycle; the watchdog then catches
  the connection loss, coalesces against the just-finished restart, and retries
  once against the fresh server.
- **Low-memory mode** for file transcription (auto on ≤8 GB RAM):
  `concurrency = 1` and a sequential 2-phase pipeline (all ASR first, then all
  LLM), to avoid whisper-server + llama-server keeping their working sets active
  simultaneously. Phase 1 streams raw ASR text into the window so the user sees
  content immediately; phase 2 replaces each chunk in place with the
  LLM-processed version.
- **`-nfa` (disable flash-attention)** flag passed to whisper-server on ≤8 GB
  machines. (Originally added under a flash-attn deadlock hypothesis; later
  analysis showed the deadlock is in Metal resource-set init, not flash-attn.
  Kept for now as a conservative reduction in Metal VRAM pressure on 8 GB;
  see backlog Phase 4.X for the decision to keep / make opt-in / remove.)
- **ASR timeout multiplier**: 4× realtime on low-RAM (was 2×) — without
  flash-attn whisper is slower; gives the watchdog room before declaring the
  server hung.

### Changed
- **`AudioConverter.splitIntoChunks` — streaming implementation**: previously
  loaded the entire WAV into a single float32 buffer (~553 MB for a 2.5 h file)
  and walked it; now reads one `target + searchWindow` window (~35 s) at a
  time via `AVAudioFile.framePosition` seeks. Peak memory is ~2 MB regardless
  of file length. Closes the failure mode where `AVAudioPCMBuffer.read` could
  silently return fewer frames than requested on RAM-constrained machines,
  leaving the second half of the file as uninitialized zeros → silent chunks
  → empty transcription.
- **File transcription window — focus and Space**: on `Transcribe File…` the
  result window is forced to the front (`orderFrontRegardless`,
  `NSApp.activate`) and joins the active Space (`collectionBehavior =
  .moveToActiveSpace`). Fixes the bug where the window opened behind other
  apps after the modal file picker stole focus.
- **File transcription window — empty chunks hidden in formatted output**:
  in plain / timestamped / SRT / Markdown renderers, chunks whose text is
  empty (silent audio or filtered-out hallucinations) are now filtered out.
  Stats line shows `N/total chunks (X empty)` when there were silent chunks,
  so the user has visibility without seeing a wall of bare `[1:18:34]` lines.

### Fixed
- File transcription pipeline diagnostics: final log line now reports the
  count and index range of empty chunks, e.g. `Transcription done in 1280s
  — 12/288 chunks empty (indices 200…211)`. Helps distinguish genuine audio
  silence from server-side failures.

### Notes
- This release packages live fixes for a known whisper.cpp/ggml-metal bug
  whose proper fix is upstream. See backlog Phase 4.X (Whisper Metal deadlock):
  watchdog (done), proactive restart every N chunks, decision on `-nfa`,
  and bumping bundled ggml/whisper.cpp to a version where Metal resource-set
  init is fixed.

## [0.4b] - 2026-05-12

### Added
- **Post-processing modes** (P5.7, P5.8): replaces the single punctuation toggle
  with three selectable modes applied to dictation and file transcription
  independently — `Off` (raw Whisper), `Smart` (combined punctuation + grammar +
  bullet-list detection in one LLM pass), and `Translate` (target language).
- **Translation mode**: translate into 13 languages (en, ru, hy, es, fr, de, it,
  pt, pl, tr, zh, ja, ko, ar). Hallucination guards (3× length, script
  preservation) are disabled for this mode since the script change is intentional.
- **Menu bar mode submenu**: status bar shows `Dictation: X` and `File: Y` with
  submenus that include all 3 modes and checkmark the current selection.
- **Settings UI**: two `NSPopUpButton`s for dictation/file modes; translate-target
  picker appears only when at least one mode is `Translate`.
- **PostProcessingPipeline** helper + `LLMProcessor` protocol — extracted
  testable post-processing contract; `LlamaClient` and `OllamaClient` conform.
- **Smoke tests** (P5.9): unit tests covering mode→prompt mapping, Codable
  round-trip, legacy `punctuationEnabled` migration, length/script guards, fail-safe
  on LLM error, tolerance of unknown raw values. Manual mode regression checklist
  (19 cases) added to TESTS.md §6.7.

### Changed
- **Config schema**: `punctuationEnabled` / `filePunctuationEnabled` (booleans)
  replaced with `dictationMode` / `fileMode` (`PostProcessingMode` enum) plus
  `translateTarget` (ISO 639-1 code). Old v0.3b configs decode transparently:
  `true → .smart`, `false → .off`. The `.smart` case persists with raw value
  `"punctuation"` to preserve this mapping.
- LLM client API: `postProcess(text:)` → `process(text:systemPrompt:)`.
- `FileTranscriptionManager.punctuationEnabled` → `mode` + `translateTarget`.
- Unknown mode raw values (e.g. `"grammar"` / `"list"` from intermediate dev
  builds) are now silently ignored on decode rather than rejecting the whole
  config.

### Fixed
- Switching dictation mode from menu bar (e.g. `Off → Translate`) now actually
  loads the LLM. Previous behaviour: config updated and saved, but no LLM was
  started, so the next dictation silently fell back to raw Whisper output.

## [0.3b] - 2026-05-07

### Added
- **Model download on first launch**: models (~3.5 GB) downloaded from GitHub
  Releases instead of bundled in .app — DMG shrunk from 3.4 GB to 9.5 MB
- **ModelManager**: sequential download with URLSession resume, SHA256 verification,
  CoreML zip/unzip, disk space check
- **ModelDownloadWindowController**: per-file progress bars, speed indicator,
  cancel/retry, localized (en/ru)
- **Hybrid Dock management**: Dock icon appears temporarily when any window is open
  (proper focus, Cmd+Tab), disappears when all windows close. Fixes invisible
  windows on LSUIElement apps
- **Replacements dictionary** (P5.4): user-defined word replacements applied after
  Whisper, before LLM. Native macOS table editor with live search field, click-to-edit
  cells, ± buttons. Menu: Replacements… (Cmd+R)
- **LLM lazy lifecycle**: when dictation punctuation is OFF but file punctuation is
  ON, LLM is loaded only during file transcription and unloaded after — saves ~2 GB
  idle RAM
- **Localization (en/ru)**: Settings window, download window with functional model
  names ("Speech recognition", "GPU acceleration", "Smart punctuation")
- **UIPreview executable target** for fast UI iteration: `./scripts/preview-ui.sh`

### Changed
- **Punctuation defaults**: dictation OFF, file transcription ON (RAM > 8 GB) —
  matches real-world usage where file transcription benefits more from LLM
- Settings window no longer floats above other apps
- Dev build version label is now `{VERSION}+dev` instead of just `dev`
- LLM startup logic refactored: `startLLMSync()` / `ensureLLMReady()` /
  `releaseLazyLLM()` helpers in AppDelegate

### Fixed
- Download window invisible after first-run wizard on other Macs (LSUIElement
  focus loss after Accessibility system dialog)
- LLM was not started when only file transcription needed it

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
