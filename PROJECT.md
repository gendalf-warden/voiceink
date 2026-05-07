# VoiceInk — Локальная голосовая диктовка для macOS

## Что это

Нативное macOS menu bar приложение для голосовой диктовки. Полностью локальное, заменяет платный Wispr Flow ($15/мес). Нажал горячую клавишу — говоришь — отпустил — текст вставляется в активное поле любого приложения.

## Текущий статус: Рабочий MVP + .app бандл

Приложение полностью функционально, используется ежедневно для реальной диктовки. Собирается в автономный .app бандл (~3.5 GB) со всеми зависимостями внутри.

**Производительность:** ASR ~1.0-1.3s + LLM ~0.3s = **~1.3-1.6s** от конца речи до вставки текста.

**Все машины:** Whisper + LLM пунктуация работают на M3 Max 36GB, M4 24GB.

---

## Стек

| Компонент | Технология | Детали |
|-----------|-----------|--------|
| Приложение | Swift 5.9, macOS 13+ | SPM, 19 файлов + 27 тестов, ~600 KB binary |
| Menu bar | NSStatusBar + NSMenu | Анимированные иконки состояния |
| Горячая клавиша | CGEventTap | Fn по умолчанию, modifier+key или Fn-only (300ms порог), auto-retry |
| Запись | AVAudioEngine | 16kHz mono PCM → WAV |
| ASR | whisper-server (subprocess) | :8178, large-v3-turbo-q5_0, Metal+CoreML |
| LLM (bundled) | llama-server (subprocess) | :8179, qwen2.5:3b, /v1/chat/completions |
| LLM (fallback) | Ollama (HTTP) | :11434, qwen2.5:3b, /api/generate |
| Вставка | NSPasteboard + CGEvent | Cmd+V, keyboard layout-aware, clipboard restore |
| Файл-транскрипция | AVFoundation | mp3/wav/m4a/mp4/mov → 16kHz WAV → whisper → LLM |
| Конфиг | ~/.config/voiceink/config.json | Codable, auto-detect paths, hot reload |
| Логи | ~/.config/voiceink/voiceink.log | Rotation 1MB, async I/O |
| Splash | NSWindow floating | Progress bar с 5 вехами загрузки |

## Архитектура

```
Pipeline:  Hotkey → Record → ASR (whisper) → LLM (llama/ollama, optional) → Paste
File:      Pick file → Convert (AVFoundation) → ASR (whisper) → LLM (optional) → Show result

                        ┌─────────────┐
                        │  main.swift │
                        └──────┬──────┘
                               │
    ┌──────────┐        ┌──────▼──────┐        ┌──────────────────┐
    │  Config  ├───────►│ AppDelegate │◄───────│SettingsWindow    │
    └──────────┘  load  │ (оркестр.)  │changed │HotkeyRecorderField│
                        └──┬──┬──┬───┘        └──────────────────┘
          ┌────────────────┘  │  └────────────────┐
          │                   │                   │
    ┌─────▼──────┐    ┌──────▼───────┐    ┌──────▼──────┐
    │HotkeyManager│    │AudioRecorder │    │StatusBar    │
    │CGEventTap   │    │AVAudioEngine │    │NSStatusBar  │
    │Fn / mod+key │    │16kHz WAV     │    │Animated     │
    │auto-retry   │    └──────────────┘    └─────────────┘
    └─────────────┘

    ┌─────────────┐    ┌──────────────┐    ┌──────────────┐
    │ Transcriber  │    │ LlamaClient  │    │ OllamaClient │
    │ HTTP POST    │    │/v1/chat/comp │    │/api/generate │
    │ timeout cfg  │    │stderr capture│    │              │
    └──────┬──────┘    └──────┬───────┘    └──────┬───────┘
           │                  │                   │
    ┌──────▼──────┐    ┌──────▼───────┐    ┌──────▼───────┐
    │whisper-server│    │ llama-server │    │   Ollama     │
    │:8178 (subpr.)│    │:8179 (subpr.)│    │:11434 (ext.) │
    │large-v3-turbo│    │qwen2.5:3b   │    │fallback      │
    └─────────────┘    └──────────────┘    └──────────────┘

    ┌─────────────────────────┐
    │ FileTranscriptionManager│
    │ AudioConverter          │
    │ TranscriptionResultWin  │
    └─────────────────────────┘

    ┌─────────────┐    ┌──────────────┐    ┌─────────────┐
    │TextInserter │    │  KeyMap      │    │   Logger    │
    │Cmd+V paste  │    │keyCodes,    │    │singleton,   │
    │layout-aware │    │mod symbols  │    │file+stdout  │
    └─────────────┘    └──────────────┘    └─────────────┘

    ┌──────────────────┐
    │SplashWindow      │
    │progress bar,     │
    │5 milestones      │
    └──────────────────┘
```

## Файлы

```
Sources/
├── VoiceInk/
│   └── main.swift                      # Entry point, NSApplication .accessory
└── VoiceInkLib/
    ├── AppDelegate.swift               # Оркестратор, pipeline, state machine, first-run → splash
    ├── AppState.swift                  # enum: idle/recording/transcribing/postProcessing/error
    ├── AudioConverter.swift            # AVFoundation: audio/video → 16kHz mono WAV
    ├── AudioRecorder.swift             # AVAudioEngine → 16kHz mono WAV
    ├── Config.swift                    # Codable, auto-detect, bundle-aware, hot reload
    ├── FileTranscriptionManager.swift  # Оркестратор файловой транскрипции + LLM
    ├── FirstRunWindowController.swift  # Wizard: Microphone + Accessibility permissions
    ├── HotkeyManager.swift             # CGEventTap, Fn-only mode, auto-retry Accessibility
    ├── KeyMap.swift                     # Key codes ↔ names, modifier symbols
    ├── LlamaClient.swift               # Bundled llama-server, /v1/chat/completions, stderr
    ├── Logger.swift                     # Singleton, file rotation 1MB
    ├── OllamaClient.swift              # HTTP client, warmup/unload, punctuation prompt
    ├── SettingsWindowController.swift   # NSWindow, HotkeyRecorderField, punctuation toggle
    ├── SplashWindowController.swift    # Splash окно с progress bar и вехами
    ├── StatusBarController.swift       # Menu bar icons, animation, info menu + version
    ├── TextInserter.swift              # Clipboard + CGEvent Cmd+V, layout-aware
    ├── TranscriptionResultWindowController.swift  # Окно результата файловой транскрипции
    ├── Transcriber.swift               # whisper-server subprocess + HTTP client
    └── StringExtensions.swift          # stripCombiningAccents() и другие расширения String

Tests/
└── VoiceInkTests/
    ├── KeyMapTests.swift               # 11 тестов: keyName, modifierSymbols, hotkeyDescription
    ├── AppStateTests.swift             # 3 теста: description, Equatable
    ├── ConfigTests.swift               # 7 тестов: Codable round-trip, backward compat, computed props
    └── StringExtensionsTests.swift     # 6 тестов: stripCombiningAccents

scripts/
└── pre-merge-check.sh                  # Валидация: swift build + swift test + release build

build-app.sh                            # Сборка: dev (.app) / release (.app + DMG)
VERSION                                 # Текущая версия (0.1b)
CHANGELOG.md                            # История изменений (Keep a Changelog)
dmg_background.png                      # Фон DMG инсталлера
```

## .app бандл

```
VoiceInk.app/Contents/
├── Info.plist                          (LSUIElement=true, bundle ID, mic usage)
├── MacOS/
│   └── voiceink                        (~600 KB binary)
└── Resources/
    ├── whisper-server                  (ASR сервер)
    ├── llama-server                    (LLM сервер)
    ├── lib/                            (whisper dylibs, 2.8 MB)
    │   ├── libwhisper.1.dylib
    │   ├── libwhisper.coreml.dylib
    │   └── libggml*.dylib              (base, cpu, blas, metal — ggml 0.9.6)
    ├── lib-llama/                      (llama dylibs + backends, 12 MB)
    │   ├── libllama.0.dylib
    │   ├── libmtmd.0.dylib
    │   ├── libggml*.dylib              (base — ggml 0.9.11, отдельно от whisper!)
    │   ├── libggml-cpu-apple_m*.so     (CPU backends: M1, M2/M3, M4)
    │   ├── libggml-metal.so            (GPU backend)
    │   ├── libggml-blas.so             (BLAS backend)
    │   ├── libomp.dylib                (OpenMP для CPU backends)
    │   ├── libssl.3.dylib             (OpenSSL)
    │   └── libcrypto.3.dylib          (OpenSSL)
    └── models/
        ├── ggml-large-v3-turbo-q5_0.bin    (547 MB, whisper)
        ├── ggml-large-v3-turbo-encoder.mlmodelc/  (1.2 GB, CoreML)
        └── qwen2.5-3b.gguf                (1.8 GB, LLM)
```

Whisper и llama dylibs в раздельных директориях (ggml версии конфликтуют). Все dylibs используют @rpath — 0 абсолютных путей на /opt/homebrew. GGML_BACKEND_PATH указывает llama-server на lib-llama/.

Сборка: `./build-app.sh` — собирает в /tmp (обход iCloud xattr), перезаписывает homebrew пути на @rpath, подписывает ad-hoc, копирует в проект.

## Реализованные функции

- [x] Push-to-talk запись (Fn по умолчанию, или любая modifier+key комбинация)
- [x] ASR через whisper-server (модель в памяти, ~1.0-1.3s на запрос)
- [x] LLM пунктуация: bundled llama-server (primary) + Ollama (fallback)
- [x] Настройка «Продвинутая пунктуация (> 8 ГБ RAM)» — выключена по умолчанию на ≤ 8 GB
- [x] Вставка текста в любое приложение (Cmd+V, layout-aware)
- [x] Menu bar с анимированными иконками состояний
- [x] Окно настроек (горячая клавиша, launch at login, privacy toggle, punctuation toggle)
- [x] Hot reload настроек без перезапуска
- [x] Fn-only горячая клавиша с порогом 300ms (короткий тап → системная функция)
- [x] Защита от утечки символов (swallowUntilRelease)
- [x] Логирование с ротацией, опция маскирования текста
- [x] Warmup LLM при старте, unload при выходе
- [x] Auto-detect путей к whisper и модели (bundle-aware)
- [x] Пробел после вставки для продолжения ввода
- [x] Автоопределение языка (русский, английский)
- [x] .app бандл со всеми зависимостями (~3.5 GB), включая OpenSSL
- [x] Splash-окно при запуске с progress bar и вехами загрузки
- [x] Auto-retry CGEventTap (не требует перезапуска после выдачи Accessibility)
- [x] Нормализация акцентов (Whisper иногда добавляет диакритику к русскому)
- [x] LlamaClient robustness: проверка процесса, timeout error, fallback, stderr capture
- [x] Транскрипция аудио/видео файлов (mp3, wav, m4a, mp4, mov) через меню "Transcribe File…"
- [x] AudioConverter: AVFoundation конвертация в 16kHz WAV без ffmpeg зависимости
- [x] .dmg инсталлер с drag-to-Applications и фоновой стрелкой
- [x] First-run wizard: запрос Microphone + Accessibility с визуальным статусом
- [x] Dev/Prod разделение: VERSION файл, dev vs release сборки, версия в Info.plist
- [x] Версия в меню (VoiceInk v0.1b)
- [x] LLM пунктуация в файловой транскрипции (тот же пайплайн что и голосовая)
- [x] Git-flow: main/develop/feature branches, rebase + ff merge, worktrees для параллельных агентов
- [x] 60 юнит-тестов (KeyMap, AppState, Config, StringExtensions, AudioConverter, Transcriber) + pre-merge валидация
- [x] CHANGELOG.md (Keep a Changelog формат)
- [x] **Chunked транскрипция файлов** — 30с чанки с разрезом по тишине, стриминг
- [x] **Параллельный pipeline** — concurrency=2 ASR+LLM, 2.1× ускорение (9× → 19× RTF на 45 мин)
- [x] **Окно результата**: прогресс-бар, live elapsed+ETA, стат скорости, экспорт TXT/SRT/MD
- [x] **Фильтр галлюцинаций**: "Продолжение следует...", lone "you", subtitle credits, standalone removal
- [x] **Языковая защита**: детект языка на первом чанке → script-check на остальных → re-transcribe при mismatch → drop если не помогло
- [x] **CJK-фильтр**: strip китайских/японских/корейских символов для не-CJK языков
- [x] **LLM translation detection**: если LLM сменил скрипт текста — использовать raw (qwen нарушает "не переводить")
- [x] **Trim trailing silence**: обрезка хвостовой тишины в AudioRecorder
- [x] **Min recording 0.5s**: игнор случайных Fn-тапов
- [x] **Undo Dictation**: Cmd+Z удаляет последнюю вставку
- [x] **Раздельные тумблеры LLM**: диктовка (on) / файлы (off) — основано на quality-эксперименте

## Известные ограничения и баги

- **Смешанные языки:** Whisper определяет один язык на аудиофрагмент
- **Размер бандла:** ~3.5 GB из-за моделей
- **macOS permissions:** First-run wizard запрашивает Microphone + Accessibility автоматически
- **8 GB RAM:** Пунктуация (LLM) отключена по умолчанию

## Конфигурация

Файл: `~/.config/voiceink/config.json`

```json
{
  "whisperCliPath": "",
  "whisperServerPath": "/path/to/whisper-server",
  "whisperModelPath": "/path/to/ggml-large-v3-turbo-q5_0.bin",
  "llamaServerPath": "/path/to/llama-server",
  "llamaModelPath": "/path/to/qwen2.5-3b.gguf",
  "language": "auto",
  "hotkeyKeyCode": 63,
  "hotkeyModifiers": [],
  "ollamaEnabled": true,
  "ollamaModel": "qwen2.5:3b",
  "ollamaEndpoint": "http://localhost:11434",
  "launchAtLogin": false,
  "logTranscriptions": true,
  "punctuationEnabled": true
}
```

Все пути автоопределяются: bundle paths → системные пути. `punctuationEnabled` по умолчанию `true` на > 8 GB, `false` на ≤ 8 GB. Hotkey по умолчанию Fn (keyCode 63).

## Сборка и запуск

```bash
# Dev mode (локальная разработка)
swift build           # debug
swift run             # запуск (нужен Ollama)

# Production: .app бандл
./build-app.sh           # dev — только .app (~3.5 GB)
./build-app.sh release   # release — .app + VoiceInk-{VERSION}.dmg
open VoiceInk.app        # запуск

# Версия берётся из файла VERSION (сейчас 0.1b)
# Dev-сборка пишет "dev" в Info.plist, release — версию из VERSION
```

## Тестирование

- `swift test` — 27 юнит-тестов (KeyMap, AppState, Config, StringExtensions)
- `./scripts/pre-merge-check.sh` — build + test + release build (0 warnings)
- `TESTS.md` — 72 ручных теста + smoke test из 7 проверок
- Тестировать на: dev (M3 Max 36GB), M4 24GB, M2 8GB

## Результаты тестирования LLM-моделей

| Модель | Размер | Русский | English | Скорость |
|--------|--------|---------|---------|----------|
| **qwen2.5:3b** (текущая) | 1.9 GB | Отлично | Отлично | 0.3-0.8s |
| qwen2.5:0.5b | 397 MB | Галлюцинации | OK | 0.2-10s |
| qwen3.5:2b | 2.7 GB | Отлично | Отлично | 0.6-0.9s |
| qwen3.5:0.8b | 1.0 GB | OK, но 11s | OK | 0.5-11s |

---

## Бэклог

### Фаза 1 — Завершена ✅
1. ~~Splash-окно при запуске~~ — done
2. ~~Auto-retry Accessibility permission~~ — done
3. ~~Настройка пунктуации для слабых машин~~ — done
4. ~~LlamaClient robustness~~ — done
5. ~~Транскрипция аудио/видео файлов~~ — done
6. ~~Dylib bundling: OpenSSL + homebrew path rewrite~~ — done

### Фаза 2 — Завершено
- ~~**2a. .dmg инсталлер**: drag-to-Applications~~ ✅
- ~~**2b. First-run wizard**: запрос Microphone + Accessibility с пояснениями~~ ✅
- ~~**2j. Dev/Prod разделение**: dev локальная, деплой только с подтверждением~~ ✅
- ~~**2k. Процесс разработки**: git-flow, тесты, коммит-конвенции, релизный процесс~~ ✅

### Фаза 3 — Раздать людям
1. **Notarization**: Apple Developer ID + notarize (без неё macOS блокирует запуск)
2. **Хостинг релизов**: GitHub Releases, манифест `latest.json` с SHA256
3. **License audit**: проверить лицензии всех встроенных компонентов (whisper.cpp, llama.cpp, ggml, qwen2.5 модель, OpenSSL, CoreML модели). Составить NOTICE.md / ACKNOWLEDGEMENTS со списком зависимостей, их лицензий и условий распространения. Убедиться что ничего не ограничивает коммерческое/массовое распространение
4. **Иконка приложения**: создать .icns для VoiceInk (видна в Dock, Finder, Login Items, Cmd+Tab). Сейчас показывает generic «exec» иконку

### Фаза 4 — Ежедневные улучшения
3. **Минимальная длина записи**: если < 0.5с — не отправлять на Whisper (случайное нажатие Fn)
4. **Отмена последней диктовки**: Cmd+Z — восстановить предыдущий clipboard

### Фаза 5 — Качество транскрипции
6. ~~**Словарь замен**~~ ✅ — TextReplacer + ReplacementsWindowController с live search, edit-on-click, нативные ±  кнопки. Применяется после Whisper, до LLM. Меню: Replacements… (Cmd+R)
7. **Режимы пост-обработки** (переключение в меню или горячей клавишей):
   - *Пунктуация* (текущий) — только знаки и заглавные
   - *Грамматика* — проверка смысловой целостности, согласования, падежей, сопряжений
   - *Список* — автоформатирование в буллеты
8. **Режим перевода**: говоришь на одном языке → текст на другом
9. **Smoke-тесты транскрипции**: эталонные WAV + проверка спецсимволов, чисел, англицизмов
10. ~~**Продвинутая транскрипция файлов A+B+D**~~ ✅ — chunked pipeline + улучшенное окно + экспорт
   - *Осталось*: C. Batch & drag-drop — multiple file selection, drag на иконку, очередь с прогрессом
   - *Осталось*: авто-сохранение рядом с исходником (video.mp4 → video.srt)

### Фаза 6 — Продвинутые фичи
10. **Голосовые команды**: "новый абзац", "точка", "удали последнее слово"
11. **Непрерывная диктовка**: toggle-режим без удержания клавиши для длинных текстов
12. **Заменить Qwen2.5-3B на permissive-licensed модель** (блокер коммерческого распространения!): текущая модель под Qwen Research License — нельзя продавать или включать в коммерческие продукты. Кандидаты на тест:
    - **Qwen2.5-1.5B-Instruct** (Apache 2.0, ~1 GB) — приоритет 1, родственная архитектура
    - **Llama 3.2 3B** (Llama license, ~2 GB) — приоритет 1, хорошее покрытие русского
    - **Phi-3-mini-4k** (MIT, Microsoft, ~2.4 GB) — приоритет 2
    - **Qwen2.5-7B-Instruct** (Apache 2.0, ~4.5 GB) — приоритет 3, если 1.5B не хватит качества
    - **Gemma 2 2B** (Gemma terms, ~1.6 GB) — приоритет 4
    Метрики сравнения: качество пунктуации (на 15-мин эталонной транскрипции), скорость на чанк, размер бандла, RAM
13. **Статистика диктовок**: счётчик слов за день/неделю/месяц
14. **Обновление whisper.cpp** (проверить ~2026-05-15): сейчас локально v1.8.3-156, upstream v1.8.4. Полезно: UTF-8 fix для русского, VAD timing fix для SRT, perf gains. Риски: 200+ коммитов в ggml, пересобрать lib/ в бандле
15. **Встроенный видеообзор** (onboarding): короткое (30-60с) видео «как пользоваться» — Fn для диктовки, Replacements, Transcribe File. Показывать новым пользователям при первом запуске (после first-run wizard) или из меню Help… → Watch tutorial. Видео либо встроенное в бандл, либо стримится с GitHub Pages. Формат — экранкаст с озвучкой

### Фаза 7 — Auto-updater (когда будут пользователи)
14. **Разделение на компоненты**: бинарник, dylibs, модели — каждый со своей версией
15. **Первая установка**: скачивает все компоненты (~3.5 GB) с прогрессом
16. **Auto-updater**: проверяет `latest.json`, скачивает только изменённое
17. **Авто-обновление при запуске**: скачать, заменить, перезапустить, прогресс в splash
18. **Fallback**: если обновление не удалось — работает на текущей версии

## Принятые решения

1. **whisper-server** как subprocess — модель в памяти, HTTP API
2. **Push-to-talk** — удерживаешь клавишу = запись, отпустил = обработка
3. **qwen2.5:3b** для пунктуации — лучший баланс качества/скорости
4. **generate API** для Ollama, **chat/completions** для llama-server
5. **Fn по умолчанию** — 300ms порог отделяет системный тап от записи
6. **Trailing space** — пробел после вставки
7. **Bundle-aware paths** — Bundle.main.resourcePath первый приоритет
8. **Сборка в /tmp** — обход iCloud Drive xattr
9. **Auto-retry CGEventTap** — каждые 2с без перезапуска
10. **Punctuation toggle** — на ≤ 8 GB LLM выключен по умолчанию
11. **AVFoundation для конвертации** — без ffmpeg, поддержка mp3/wav/m4a/mp4/mov
12. **Полный dylib bundling** — включая OpenSSL, все homebrew пути перезаписаны на @rpath
13. **Раздельные lib директории** — whisper (lib/) и llama (lib-llama/) из-за конфликта версий ggml
14. **GGML_BACKEND_PATH** — env variable для llama-server, указывает на бандлённые .so плагины
15. **Файловая транскрипция с LLM** — тот же пайплайн что и голосовая диктовка
16. **DMG инсталлер** — create-dmg, фон 600x400 1x с drag-стрелкой, сборка в /tmp
17. **First-run wizard** — проверяет реальный статус permissions (не флаг в конфиге), floating окно, polling каждые 1.5с
18. **VERSION файл** — нотация 0.Xb (бета), dev-сборка → "dev" в Info.plist, release → версия из файла
19. **Версия в меню** — CFBundleShortVersionString из Info.plist, fallback "dev"
20. **Git-flow** — main (релизы) → develop (интеграция) → feature/* (агенты), rebase + ff merge
21. **TDD** — XCTest target, юнит-тесты для чистой логики, pre-merge валидация обязательна
22. **Worktrees** — параллельные агенты в /tmp/voiceink-<name>, изоляция файлов и .build кэша
23. **Диктовка как нативная функция ОС** — приложение ведёт себя как встроенная функция macOS: пользователь диктует законченными предложениями, текст вставляется в любое активное поле. Не ассистент, не чат-бот — просто голос → текст
