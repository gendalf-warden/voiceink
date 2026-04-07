# VoiceInk — Roadmap

## Готово
- [x] MVP: menu bar app (Swift, NSStatusBar)
- [x] Push-to-talk горячая клавиша (Ctrl+1, CGEventTap)
- [x] Запись аудио (AVAudioEngine → 16kHz WAV)
- [x] whisper-server (модель в памяти, ~1.1s на фразу)
- [x] LLM-постпроцессинг пунктуации (qwen2.5:3b via Ollama, ~1.5s)
- [x] Вставка текста (NSPasteboard + CGEvent Cmd+V)
- [x] Автоопределение языка (ru/en)
- [x] Бенчмарк и сравнение с Wispr Flow

## Следующие задачи
1. Автозапуск при логине
2. Настройки через меню (выбор модели, вкл/выкл LLM, горячая клавиша)
3. История диктовок (последние 10)
4. Пользовательский словарь (имена, термины — передаётся в LLM-промпт)
5. Сборка .app (нормальное приложение в /Applications)
