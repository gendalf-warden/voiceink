# VoiceInk

Нативное macOS menu bar приложение для локальной голосовой диктовки. Замена Wispr Flow ($15/мес). Полностью автономный .app бандл — все зависимости внутри.

Текущая версия: **0.1b** (файл `VERSION`).

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
- Нотация: `0.Xb` (бета), потом `1.0` и далее
- `build-app.sh` — dev: версия "dev" в Info.plist, без DMG
- `build-app.sh release` — версия из VERSION, `VoiceInk-0.1b.dmg`, SHA256, симлинк `VoiceInk.dmg`
- Версия отображается в menu bar: "VoiceInk v0.1b"

## Структура

- `Sources/VoiceInk/main.swift` — entry point
- `Sources/VoiceInkLib/` — вся логика (20 файлов)
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
  - `Logger.swift` — singleton, file rotation 1MB
  - `AppState.swift` — enum: idle/recording/transcribing/postProcessing/error
  - `StringExtensions.swift` — `stripCombiningAccents()` и другие расширения String
  - `AsyncSemaphore.swift` — actor-based async семафор для concurrency limit
- `Tests/VoiceInkTests/` — юнит-тесты (60 тестов)
  - `KeyMapTests.swift`, `AppStateTests.swift`, `ConfigTests.swift`, `StringExtensionsTests.swift`, `AudioConverterTests.swift`, `TranscriberTests.swift`
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

- **iCloud Drive**: сборка бандла и DMG в /tmp, иначе `com.apple.provenance` xattr ломает codesign/hdiutil
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
