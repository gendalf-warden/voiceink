# VoiceInk

Нативное macOS menu bar приложение для локальной голосовой диктовки. Замена Wispr Flow ($15/мес). Полностью автономный .app бандл — все зависимости внутри.

**Расположение**: `/Users/dima/CLAUDE PROJECTS/VoiceInk` (вынесен из iCloud Drive 2026-06 — см. «Важные технические детали»). Бэкап = GitHub `gendalf-warden/voiceink`, НЕ iCloud.

Текущая версия: см. файл `VERSION` (на момент написания — `0.5.013`).

## Сборка

```bash
swift build              # debug (dev mode, использует системные пути)
swift run                # запуск dev mode (нужен Ollama)
./build-app.sh           # dev: .app бандл, версия "dev", без DMG — быстрый цикл
./build-app.sh release   # release: .app + DMG с версией из VERSION, SHA256
open VoiceInk.app        # запуск бандла
```

Требования: macOS 13+, Xcode CLI Tools.

Для dev-mode (swift run): Ollama с qwen2.5:3b (`ollama serve` + `ollama pull qwen2.5:3b`).

Для .app бандла: whisper.cpp build, llama-server (homebrew), модели — всё копируется build-app.sh.

## Версионирование

- Файл `VERSION` в корне — единственный источник правды
- **Нотация: `MAJOR.MINOR.PATCH`**, патч трёхзначный с лидирующими нулями. Пример: `0.5.001`, `0.5.002`, …, `0.5.099`, `0.5.100`
  - **PATCH** (третий блок) бампится на ЛЮБОЕ изменение кода/конфига/докуметации, независимо от того, выпущено это уже наружу или нет. Бамп идёт ВМЕСТЕ с изменением (в той же сессии), не «потом перед билдом» — иначе одна версия начинает означать разное содержимое. **Чек для агента**: перед тем как написать «В копилке (не собрано): …» — убедись что VERSION уже отражает новое содержимое
  - **MINOR** (второй блок) бампится только при серьёзной новой функциональности и только по согласованию с Димой
  - **MAJOR** (первый блок) — отдельное решение (например при 1.0)
  - Старое обозначение `0.Xb` (бета) больше не используется
- `build-app.sh` — dev: версия `<VERSION>+dev` в Info.plist (например `0.5.001+dev`), без DMG
- `build-app.sh release` — версия из VERSION, `VoiceInk-0.5.001.dmg`, SHA256, симлинк `VoiceInk.dmg`
- Версия отображается в menu bar: "VoiceInk v0.5.001"

## Auto-update (Sparkle 2.x)

- **Меню**: «Check for Updates…» в menu bar → дёргает `SPUStandardUpdaterController.checkForUpdates(_:)`.
- **Конфиг** в Info.plist (генерируется `build-app.sh`):
  - `SUFeedURL` = `https://github.com/gendalf-warden/voiceink/releases/latest/download/appcast.xml`
  - `SUPublicEDKey` = base64 публичный ed25519 ключ. Сейчас `h4npNcO5Ft60v0dq3Nxs/un8eRGmdxhjhkfi0MKos3s=`. Если поменять — все existing-installations перестанут получать апдейты до ручной переустановки. При компрометации меняем + публикуем новый Sparkle-enabled релиз вручную всем.
  - `SUEnableAutomaticChecks` = `false` (только manual check, по согласованию с Димой)
- **Приватный ключ**: macOS Keychain, account `Sparkle-VoiceInk-EdDSA`, никогда не покидает Keychain кроме `./scripts/sparkle-generate-keys.sh export` для бэкапа.
- **Sparkle.framework** копируется в `VoiceInk.app/Contents/Frameworks/Sparkle.framework` из `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/`. Внутренние XPCServices + Updater.app + Autoupdate подписываются отдельно (deepest-first порядок) перед подписью bundle.
- **Скрипты**:
  - `./scripts/sparkle-generate-keys.sh` — one-time генерация / import / export ключей
  - `./scripts/sparkle-sign-dmg.sh path/to/DMG` — печатает `sparkle:edSignature="..." length="..."` для appcast.xml
- **Релиз**: `./scripts/release.sh` теперь генерирует и публикует `appcast.xml` (помимо `latest.json`) в GitHub Release.
- **Первая Sparkle-сборка**: 0.5.002. Пользователи на pre-0.5.002 версиях НЕ могут авто-апдейтиться — должны вручную скачать 0.5.002 первый раз.

## Структура

- `Sources/VoiceInk/main.swift` — entry point
- `Sources/VoiceInkLib/` — вся логика (22 файла)
  - `AppDelegate.swift` — оркестратор, pipeline, state machine, first-run wizard → splash при старте
  - `Transcriber.swift` — whisper-server subprocess (:8178) + HTTP client, configurable timeout
  - `LlamaClient.swift` — bundled llama-server subprocess (:8179) + /v1/chat/completions, GGML_BACKEND_PATH, stderr capture
  - `OllamaClient.swift` — Ollama fallback, generate API (не chat)
  - `HotkeyManager.swift` — CGEventTap, Fn-only (300ms порог), auto-retry при отсутствии Accessibility
  - `Config.swift` — Codable, auto-detect paths, bundle-aware, punctuation toggle, Fn default hotkey
  - `FirstRunWindowController.swift` — wizard при первом запуске: Microphone + Accessibility с пояснениями
  - `SplashWindowController.swift` — окно загрузки с progress bar и вехами
  - `SettingsWindowController.swift` — настройки, hotkey recorder, punctuation toggle
  - `StatusBarController.swift` — menu bar иконки, анимация, инфо-меню с версией, Transcribe File
  - `AudioRecorder.swift` — AVAudioEngine → 16kHz mono WAV
  - `AudioConverter.swift` — конвертация audio/video файлов в 16kHz mono WAV через AVFoundation
  - `FileTranscriptionManager.swift` — оркестратор файловой транскрипции: picker → convert → transcribe → LLM → result
  - `TranscriptionResultWindowController.swift` — окно результата транскрипции с Copy
  - `TextInserter.swift` — Clipboard + CGEvent Cmd+V, layout-aware
  - `KeyMap.swift` — key codes ↔ names, modifier symbols
  - `Logger.swift` — singleton, file rotation 1MB. `~/.config/voiceink/voiceink.log` (+ `.old`). Каждый запуск пишет diagnostic-баннер (версия+build, чип, macOS, RAM, mic/accessibility пермишены, хоткей, режимы, список bundled ggml `.so` рядом с llama-server). Field-логи: длительность+пик амплитуды записи, что вырезал hallucination-фильтр (rejected junk логируется verbatim), классификация хоткея (PTT vs Fn+combo). Реальный текст диктовки — только под `logTranscriptions` (privacy), иначе `[N chars, M words]`
  - `AppState.swift` — enum: idle/recording/transcribing/postProcessing/error
  - `StringExtensions.swift` — `stripCombiningAccents()` и другие расширения String
  - `AsyncSemaphore.swift` — actor-based async семафор для concurrency limit
  - `TextReplacer.swift` — user-defined word replacements (word-boundary regex, case-insensitive)
  - `ReplacementsWindowController.swift` — окно редактора словаря замен с live search
  - `UpdateController.swift` — обёртка над Sparkle `SPUStandardUpdaterController`. Метод `checkForUpdates()` вызывается из menu bar. Конфиг в Info.plist (SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks=false). Логирует lifecycle через `SPUUpdaterDelegate`
- `Sources/UIPreview/main.swift` — fast UI iteration harness (swift run UIPreview)
- `Tests/VoiceInkTests/` — юнит-тесты (73 теста)
  - `KeyMapTests.swift`, `AppStateTests.swift`, `ConfigTests.swift`, `StringExtensionsTests.swift`, `AudioConverterTests.swift`, `TranscriberTests.swift`, `TextReplacerTests.swift`
- `scripts/pre-merge-check.sh` — валидация перед мержем (build + test + release build)
- `CHANGELOG.md` — история изменений по версиям (Keep a Changelog)
- `build-app.sh` — сборка .app бандла в /tmp (обход iCloud xattr), dylib bundling, DMG (release only)
- `VERSION` — текущая версия приложения
- `dmg_background.png` — фон для DMG инсталлера (стрелка drag-to-Applications)

## Конвенции

- Swift 5.9, SPM (не Xcode project)
- Логирование через глобальный `log()` (Logger.swift), не `print()`
- Конфиг: `~/.config/voiceink/config.json`, Codable с `decodeIfPresent` для новых полей
- LLM приоритет: bundled llama-server → Ollama fallback
- Ollama: generate API (`/api/generate`), не chat API
- llama-server: `/v1/chat/completions` (нужен chat template для system prompt)
- Горячая клавиша: Fn по умолчанию, любая modifier+key комбинация или Fn-only
- Все key codes и modifier symbols — через KeyMap.swift (не дублировать)
- Bundle-aware paths: `Bundle.main.resourcePath` первый приоритет в detectDefaults()

## Не трогать

- Модель qwen2.5:3b — протестирована, лучший баланс. Не менять без тестов
- whisper-server подход (subprocess + HTTP) — валидирован, не переключать на CLI
- Формат аудио 16kHz mono PCM — требование whisper
- llama-server endpoint `/v1/chat/completions` — НЕ `/completion` (без chat template LLM добавляет контент вместо пунктуации)

## Важные технические детали

- **Репозиторий вне iCloud Drive** (2026-06): живёт в `/Users/dima/CLAUDE PROJECTS/VoiceInk`, бэкап = GitHub. Раньше был в iCloud — это плодило конфликт-копии (`… 2.app`, `… 2.dmg`, `… 2.png`) и угрожало целостности `.git`. Сборка бандла и DMG по-прежнему в /tmp (чистота codesign/hdiutil, изоляция .build). Если репо когда-либо снова окажется в iCloud — `com.apple.provenance`/`com.apple.FinderInfo` xattr ломают codesign/hdiutil
- **Dylib bundling**: whisper и llama динамически слинкованы с разными версиями ggml. Whisper dylibs в `Resources/lib/`, llama dylibs в `Resources/lib-llama/` (раздельные директории, чтобы ggml версии не конфликтовали). Абсолютные homebrew пути перезаписываются на @rpath через install_name_tool
- **GGML backend plugins**: llama-server загружает .so бэкенды (Metal, CPU, BLAS) динамически через `GGML_BACKEND_PATH`. Плагины + libomp.dylib в `lib-llama/`. LlamaClient.swift устанавливает env variable при запуске процесса
- **CoreML**: whisper использует `ggml-large-v3-turbo-encoder.mlmodelc` (1.2 GB) для GPU-ускорения
- **Accessibility retry**: HotkeyManager пробует создать CGEventTap каждые 2с пока не получит разрешение — не требует перезапуска
- **First-run wizard**: показывается если Microphone ИЛИ Accessibility не выданы (проверяет реальное состояние, не флаг). Floating window, временно опускается при запросе Accessibility чтобы системный диалог был виден
- **Punctuation toggle**: настройка «Продвинутая пунктуация (> 8 ГБ RAM)» — выключена по умолчанию на машинах ≤ 8 GB, полностью отключает LLM
- **Combining accents**: Whisper иногда добавляет диакритику к русскому тексту — `stripCombiningAccents()` фильтрует Unicode 0x0300-0x036F
- **LlamaClient robustness**: startServer() кидает ошибку если сервер не стартовал, waitForServer() проверяет что процесс жив, warmup() помечает сервер мёртвым при ошибке, stderr логируется при крэше
- **File transcription**: поддержка mp3/wav/m4a/mp4/mov через AVFoundation (без ffmpeg), конвертация в 16kHz WAV, chunked (30с по тишине) + параллельный pipeline (concurrency=2, +2.1× скорость), streaming в окно
- **Language filtering**: детект языка на первом чанке → scriptMatches на остальных → re-transcribe при mismatch → drop если не помогло. CJK-фильтр. Post-LLM script-check (ловит переводы qwen'а)
- **Hallucination filters**: `Transcriber.removeHallucinations()` — "Продолжение следует...", lone "you", subtitle credits. Standalone-чанки целиком удаляются. 3× length guard в AppDelegate/FileTranscriptionManager
- **Smart punctuation split**: `config.punctuationEnabled` — для диктовки (on), `config.filePunctuationEnabled` — для файлов (off по умолчанию). Основано на quality-эксперименте: LLM иногда перефразирует и меняет слова
- **LLM lazy lifecycle**: dictation=on → eager load на старте; dictation=off+files=on → lazy load на каждой файловой транскрипции, выгрузка после; обе off → не загружается. Helpers: `startLLMSync`/`ensureLLMReady`/`releaseLazyLLM`. FileTranscriptionManager использует callbacks `onLLMNeeded`/`onLLMRelease`
- **Replacements**: `config.replacements: [String: String]` — пользовательский словарь замен. Применяется через `TextReplacer.apply()` после Whisper, до LLM. Word-boundary, case-insensitive search, verbatim replacement
- **UIPreview target**: для быстрой итерации UI без бандла — `./scripts/preview-ui.sh [window]`. Изолирует конфиг в `/tmp` через env `VOICEINK_CONFIG_DIR`

## Решённые баги

### llama-server крэшил на другом Mac
**Причина**: коллизия ggml dylibs — whisper (0.9.6) и llama (0.9.11) использовали одноимённые dylibs. build-app.sh копировал whisper'овские первыми, llama'шные пропускались из-за `[ -f ... ] && return 0` в copy_dylib().

**Фикс**: раздельные директории — whisper dylibs в `lib/`, llama dylibs в `lib-llama/`, каждый сервер с отдельным @rpath.

### llama-server "no backends are loaded"
**Причина**: ggml backend plugins (.so) загружаются динамически, а не через линковку. Хардкод-путь `/opt/homebrew/Cellar/ggml/...` в libggml.0.dylib не работает в бандле.

**Фикс**: копирование .so + libomp.dylib в `lib-llama/`, установка `GGML_BACKEND_PATH` env variable в LlamaClient.swift.

### AudioConverter "Cannot create WAV writer"
**Причина**: `AVAssetWriterInput(outputSettings: nil)` (passthrough) не поддерживается для `.wav` формата.

**Фикс**: передать явные PCM outputSettings (16kHz mono 16-bit) в writer input.

### Whisper Metal deadlock на длинных файлах (НЕ полностью решено, есть обходник)
**Симптом**: при транскрипции файлов >~75 мин whisper-server залипает после ~150-180 `/inference` запросов. Все последующие чанки → URLError.timedOut. Сервер живой (status S), RSS ~700МБ, не падает. Воспроизводится на M3 Max 36ГБ и M-чип 8ГБ — **не RAM-зависимо**.

**Стек hang'а** (через `sample <pid>`):
- DispatchQueue worker: `__ggml_metal_rsets_init_block_invoke` (libggml-metal.0.9.6.dylib) → usleep → nanosleep → __semwait_signal (retry-loop)
- httplib worker: `main::$_2::operator()` → `std::mutex::lock()` → __psynch_mutexwait (заблокирован на mutex, который держит Metal-thread)
- Main thread: `std::thread::join` → __ulock_wait

**Причина**: баг в `libggml-metal.0.9.6.dylib` — кумулятивная утечка/исчерпание Metal resource sets. Каждый `/inference` оставляет аллокацию, после ~150 запросов Metal-аллокатор не может выделить новый resource set и крутит retry с usleep, удерживая inference-mutex.

**Обходник (0.5.001)**: `Transcriber.sendInferenceWithWatchdog` — на URL timeout/connection lost вызывает `restartServer()` (kill + 1.5с пауза + start + waitForServer). Restart-breaker на 10 попыток. Активен для всех вызовов (диктовка + файлы), всех машин.

**Долгосрочный фикс**: обновить bundled ggml/whisper.cpp до версии, где Metal init не утекает. См. PROJECT.md Фаза 4.X п.9 и Фаза 6 п.14.

**НЕ путать с**: `-nfa` (no-flash-attn) — был добавлен в гипотезе про FA, но стек показал что FA здесь не при чём. Сейчас `-nfa` ограничен ≤8ГБ. Можно безопасно убрать (см. бэклог Фаза 4.X п.8).

### Orphaned whisper-server / llama-server processes
**Симптом**: на 8 ГБ Mac при тяжёлой диктовке whisper-server piling up (~600 МБ each, видели 3-4 одновременно). VoiceInk shutdown() вызывался только из Quit menu item, не из applicationWillTerminate; SIGTERM/SIGINT/Settings-uninstall/crash → child processes reparented to launchd, держат порт 8178, новый сервер не может bind, watchdog рестартит свой dead процесс.

**Фикс (0.5.008)**: `Sources/VoiceInkLib/ProcessHygiene.swift` — `killOrphans(executablePath:port:label:)`. Парсит `ps -axo pid=,command=` для exact-match по нашему bundled executable path, плюс `lsof -ti :PORT` для cross-check. SIGKILL. Вызывается из AppDelegate ПЕРЕД `transcriber.startServer()` / `llamaClient.startServer()`. Также добавлен `applicationWillTerminate(_:)` который зовёт idempotent `shutdown()`. Покрывает crash/SIGKILL/jetsam через next-launch sweep (никак иначе не дотянуться).

### Clipboard paste race
**Симптом**: dictation paste'ил ПРЕДЫДУЩИЙ clipboard вместо транскрипции. На 8 ГБ под memory pressure target app не успевал прочитать pasteboard за 150 мс — restore old contents выигрывал гонку.

**Фикс (0.5.008)**: `TextInserter.insert()` теперь: (a) сохраняет ВСЕ pasteboard items + types (не только `.string` — image/RTF/file URLs больше не теряются); (b) capture `pasteboard.changeCount` после нашего write; (c) restore delay 150ms → 600ms; (d) перед restore проверяет `shouldRestoreClipboard(changeCountAtOurWrite:changeCountNow:)` — если user скопировал что-то после диктовки (changeCount вырос), restore skipped.

### Gatekeeper unfriendly first-launch dialog on macOS 15
**Симптом**: новые пользователи качают DMG из Safari → первый запуск показывает «Apple could not verify VoiceInk is free of malware» с Done/Move to Trash → требует System Settings → Privacy & Security → Open Anyway. Сравнение с Dion (другой DMG-distributed app) показало что friendly диалог «App downloaded from Internet — Open?» возможен на той же macOS 15.7.4.

**Стадия 1 (0.5.009, частично)**: `codesign --verify --deep --strict` выявил `Disallowed xattr com.apple.FinderInfo found on Sparkle.framework/Versions/B/Updater.app`. iCloud File Provider клеит `com.apple.FinderInfo` + `com.apple.fileprovider.fpfs#P` на каждый файл когда .app копируется в iCloud Drive. Build pipeline переписан: ВСЁ остаётся в `/tmp` (BUNDLE → FINAL_BUNDLE → DMG creation → notarize → staple), в iCloud копируется только готовый DMG + dev-mirror .app в конце. `codesign --strict` passes — но первый-launch диалог всё ещё unfriendly.

**Стадия 2 (0.5.010, корневой фикс)**: удалили `com.apple.security.cs.disable-library-validation` из `entitlements.plist`. Apple macOS 15 Reputation Engine факторит это entitlement в risk assessment и эскалирует к strict диалогу даже у полностью notarized apps. Все наши bundled libs/.so/Sparkle internals подписаны нашим team `94QK2GK5GT` через `sign_one` в build-app.sh, поэтому library validation проходит нативно. Verify: friendly диалог появился на 0.5.010, оба бандл-сервера (`whisper-server --help`, `llama-server --version`) запускаются без ошибок без этого entitlement.

**Оставшиеся entitlements** (нужны для GGML Metal compute): `com.apple.security.cs.allow-jit`, `com.apple.security.cs.allow-unsigned-executable-memory`. Не триггерят strict диалог (проверено).

### Phantom "Thank you" / "click click click" в документах (баг Анны)
**Симптом**: пользователь оформляет доки (НЕ диктует), а в текст сами по себе вставляются «Thank you.» и «click click click click» — посреди слова («Matosinhos» → «M Thank you. atosinhos»).

**Диагноз по логу** (`voiceink_Anna.log`): хоткей = `Fn` (дефолт). Цепочка из 3 звеньев: (1) `Fn` удерживается >300ms в составе комбо (`Fn`+стрелки, `Fn`+Delete, `Fn`+F-клавиши) → push-to-talk стартует запись; (2) запись ловит тишину/стук клавиш → Whisper галлюцинирует (тишина → «Thank you.» = ровно 10 символов; в логе 5.2s→7, 6.6s→10, 2.2s→10 символов; стук клавиш → «click click click»); (3) `removeHallucinations()` не ловил эти паттерны, а LLM-очистка у Анны мертва (bundled llama падает на старте, см. ниже).

**Фикс (0.5.011)**, три независимых:
- `HotkeyManager`: в `Fn`-only режиме нажатие любой клавиши пока `Fn` удерживается → это `Fn`+комбо, не PTT → `fnComboUsed=true`, таймер записи отменяется.
- `AudioRecorder.isSilent(url:)`: пик амплитуды по всему файлу ниже speech-floor (0.01) → запись тишины, `AppDelegate` дропает до транскрипции.
- `Transcriber.removeHallucinations()`: добавлены standalone-only фразы (`thank you`, `thanks`, `bye`, `спасибо`…, не вырезаются в середине предложения), `isRepeatedWordLoop()` (один короткий токен ≥3× = петля повторов), и RU «спасибо за просмотр».

### Bundled llama-server "no backends are loaded" на машине пользователя (баг #2, исправлено 0.5.012)
**Симптом**: на машине Анны (и не только) bundled llama-server падал на КАЖДОМ старте — stderr `no backends are loaded` + `fitting params to device memory`, exit 1. → фолбэк на Ollama (не установлена) → LLM post-processing не работал ВООБЩЕ, всегда raw Whisper.

**Корневая причина**: новый ggml (0.9.11) ищет backend-плагины (`.so`: Metal/CPU/BLAS) двумя способами — (1) relocatable-поиск в директории, где лежит **исполняемый файл** (`llama-server` → `Resources/`), импортирует `__NSGetExecutablePath`; (2) захардкоженный на этапе компиляции абсолютный путь `/opt/homebrew/Cellar/ggml/<ver>/libexec`. При этом `GGML_BACKEND_PATH` делает `dlopen` ОДНОГО конкретного **файла**, а НЕ сканирует директорию. Старая схема (`.so` в `lib-llama/` + `GGML_BACKEND_PATH=lib-llama`) на чистой машине не грузила ничего: Cellar-путь отсутствует, а dir-значение env'а игнорируется (`dlopen(dir)` → «not a file»). На dev-машинах «работало» только потому, что Cellar существует локально.

**Фикс (0.5.012)**: `build-app.sh` копирует backend `.so` в `Resources/` РЯДОМ с `llama-server` (их dylib-зависимости — `libggml-base`, `libomp` — остаются в `lib-llama/`, резолвятся через rpath `@loader_path/lib-llama` на самих `.so` + `@executable_path/lib-llama` на `llama-server`). `LlamaClient` больше НЕ ставит dir-значение `GGML_BACKEND_PATH`. Relocatable executable-dir поиск ggml находит бэкенды на любой машине. whisper-server (старее whisper.cpp, без `.so`-плагин-лоадера и без `__NSGetExecutablePath`) эти файлы игнорирует — коллизии версий ggml нет.

**Верификация**: после сборки прогнать `<bundle>/Contents/Resources/llama-server --version` с временно убранным `/opt/homebrew/Cellar/ggml/*/libexec` (или на чистой машине) — в логе должно быть `load_backend: loaded ... from <bundle>/Contents/Resources/libggml-*.so`, НЕ из Cellar.

## Процесс разработки

### Git Flow
- **main** — только релизы, каждый коммит = тег
- **develop** — интеграция, все фичи сливаются сюда
- **feature/<name>** — одна фича = один агент = одна ветка, создаётся от develop
- **release/<version>** — стабилизация перед релизом
- Мерж: rebase + fast-forward (линейная история)
- Параллельные агенты работают в worktrees (`git worktree add /tmp/voiceink-<name> feature/<name>`)

### Коммиты
- Формат: `<type>(<scope>): <description>`
- Типы: `feat`, `fix`, `refactor`, `test`, `docs`, `build`, `chore`
- Скоупы: `config`, `keymap`, `hotkey`, `transcriber`, `llm`, `ui`, `build`, `history`, `tests`

### Commit cadence (защита от потери работы)
- **Коммит ≠ сборка.** «Копилка» (build-on-command) относится ТОЛЬКО к сборке .app/DMG. Код коммитим и пушим в `develop` СРАЗУ после каждого логического изменения, не накапливая. Один gap уже стоил 3 недель незакоммиченной работы (всё 0.5.001→0.5.010 лежало в рабочем дереве, в git/GitHub была только v0.5b).
- Быстрый способ: `./scripts/save.sh ["msg"]` — `git add -A` + commit + push текущей ветки.
- `develop` всегда трекает `origin/develop` → `git status` показывает «ahead», если есть незапушенное. `pre-merge-check.sh` тоже предупреждает.
- К концу сессии: working tree чистый и запушенный (или явно перечислен в копилке).

### Перед мержем в develop
- `swift build` — 0 warnings
- `swift test` — все тесты проходят
- Или запустить `./scripts/pre-merge-check.sh`
- Человек ревьюит diff и подтверждает

### Релизный процесс
1. `git checkout -b release/X.Xb develop`
2. Bump VERSION, обновить CHANGELOG.md
3. Полный тестовый цикл (swift test + TESTS.md regression)
4. `./build-app.sh release` → DMG + SHA256
5. Мерж в main, тег `vX.Xb`
6. Back-merge в develop

## Тестирование

### Автоматические (swift test)
- 27 юнит-тестов: KeyMap, AppState, Config (Codable, backward compat), StringExtensions
- Запуск: `swift test`
- Тесты в `Tests/VoiceInkTests/`

### Ручные (TESTS.md)
- 72 регрессионных теста, smoke test из 7 проверок
- После изменений кода: `swift build` + `swift test` + smoke test
- После изменений бандла: `./build-app.sh` + `open VoiceInk.app` + smoke test
- Перед релизом: полная регрессия на нескольких машинах (M3 Max 36GB, M4 24GB, M2 8GB)

## Документация

- `CLAUDE.md` — инструкции для агентов (этот файл)
- `PROJECT.md` — полный статус, архитектура, бэклог, принятые решения
- `CHANGELOG.md` — история изменений по версиям
- `TESTS.md` — чеклист регрессионных тестов
- `architecture.html` — интерактивная диаграмма (открыть в браузере)
